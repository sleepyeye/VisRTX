/*
 * Copyright (c) 2019-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include "gpu/shading_api.h"

namespace visrtx {

enum class RayType
{
  PRIMARY = 0,
  SHADOW = 1
};

struct RayAttenuation
{
  const Ray *ray{nullptr};
  float attenuation{0.f};
};

DECLARE_FRAME_DATA(frameData)

// Helper functions ///////////////////////////////////////////////////////////

RT_FUNCTION float attenuation(ScreenSample &ss, Ray r)
{
  RayAttenuation ra;
  ra.ray = &r;
  intersectVolume(
      ss, r, RayType::SHADOW, &ra, OPTIX_RAY_FLAG_DISABLE_CLOSESTHIT);
  return ra.attenuation;
}

RT_FUNCTION vec3 computeLightConrib(ScreenSample &ss, const SurfaceHit &hit)
{
  const auto &scivisParams = frameData.renderer.params.scivis;

  auto &world = frameData.world;

  const vec3 shadePoint = hit.hitpoint + (hit.epsilon * hit.Ns);

  vec3 contrib(0.f);
  for (size_t i = 0; i < world.numLightInstances; i++) {
    auto *inst = world.lightInstances + i;
    if (!inst)
      continue;

    for (size_t l = 0; l < inst->numLights; l++) {
      auto ls = sampleLight(ss, hit, inst->indices[l]);
      Ray r;
      r.org = shadePoint;
      r.dir = ls.dir;
      r.t.upper = ls.dist;
      if (!isOccluded(ss, r, RayType::SHADOW)) {
        contrib += ls.radiance * dot(ls.dir, hit.Ns) * scivisParams.lightFalloff
            * (1.f - attenuation(ss, r));
      }
    }
  }
  return contrib;
}

// OptiX programs /////////////////////////////////////////////////////////////

RT_PROGRAM void __closesthit__shadow()
{
  // no-op
}

RT_PROGRAM void __anyhit__shadow()
{
  if (ray::isIntersectingSurfaces()) {
    SurfaceHit hit;
    ray::populateSurfaceHit(hit);
    const auto &material = *hit.material;
    const auto matValues = getMaterialValues(frameData, material, hit);
    if (matValues.opacity >= 0.99f) {
      auto &occluded = ray::rayData<uint32_t>();
      occluded = true;
      optixTerminateRay();
    } else
      optixIgnoreIntersection();
  } else {
    auto &ra = ray::rayData<RayAttenuation>();
    VolumeHit hit;
    ray::populateVolumeHit(hit);
    rayMarchVolume(ray::screenSample(), hit, ra.attenuation);
    if (ra.attenuation < 0.99f)
      optixIgnoreIntersection();
  }
}

RT_PROGRAM void __closesthit__primary()
{
  ray::populateHit();
}

RT_PROGRAM void __miss__()
{
  // TODO
}

RT_PROGRAM void __raygen__()
{
  const auto &rendererParams = frameData.renderer;
  const auto &scivisParams = rendererParams.params.scivis;

  /////////////////////////////////////////////////////////////////////////////
  // TODO: clean this up! need to split out Ray/RNG, don't need screen samples
  auto ss = createScreenSample(frameData);
  if (pixelOutOfFrame(ss.pixel, frameData.fb))
    return;
  auto ray = makePrimaryRay(ss);
  float tmax = ray.t.upper;
  /////////////////////////////////////////////////////////////////////////////

  SurfaceHit surfaceHit;
  VolumeHit volumeHit;
  vec3 outputColor(0.f);
  vec3 outputNormal = ray.dir;
  float outputOpacity = 0.f;
  float depth = 1e30f;
  uint32_t primID = ~0u;
  uint32_t objID = ~0u;
  uint32_t instID = ~0u;
  bool firstHit = true;

  while (outputOpacity < 0.99f) {
    ray.t.upper = tmax;
    surfaceHit.foundHit = false;
    intersectSurface(ss, ray, RayType::PRIMARY, &surfaceHit);

    vec3 color(0.f);
    float opacity = 0.f;

    if (surfaceHit.foundHit) {
      uint32_t vObjID = ~0u;
      uint32_t vInstID = ~0u;
      const float vDepth = rayMarchAllVolumes(ss,
          ray,
          RayType::PRIMARY,
          surfaceHit.t,
          color,
          opacity,
          vObjID,
          vInstID);

      if (firstHit) {
        const bool volumeFirst = vDepth < surfaceHit.t;
        if (volumeFirst) {
          outputNormal = -ray.dir;
          depth = vDepth;
          primID = 0;
          objID = vObjID;
          instID = vInstID;
        } else {
          outputNormal = surfaceHit.Ng;
          depth = surfaceHit.t;
          primID = surfaceHit.primID;
          objID = surfaceHit.objID;
          instID = surfaceHit.instID;
        }
        firstHit = false;
      }

      const auto &material = *surfaceHit.material;
      const auto matValues = getMaterialValues(frameData, material, surfaceHit);

      const float aoFactor = (scivisParams.aoSamples > 0 ? computeAO(ss,
                                  ray,
                                  RayType::SHADOW,
                                  surfaceHit,
                                  rendererParams.occlusionDistance,
                                  scivisParams.aoSamples)
                                                         : 1.f)
          * rendererParams.ambientIntensity;

      accumulateValue(color,
          (matValues.baseColor
              * (computeLightConrib(ss, surfaceHit)
                  + (rendererParams.ambientColor * aoFactor
                      * scivisParams.lightFalloff))),
          opacity);
      accumulateValue(opacity, matValues.opacity, opacity);

      color *= opacity;
      accumulateValue(outputColor, color, outputOpacity);
      accumulateValue(outputOpacity, opacity, outputOpacity);

      ray.t.lower = surfaceHit.t + surfaceHit.epsilon;
    } else {
      uint32_t vObjID = ~0u;
      uint32_t vInstID = ~0u;
      const float volumeDepth = rayMarchAllVolumes(ss,
          ray,
          RayType::PRIMARY,
          ray.t.upper,
          color,
          opacity,
          vObjID,
          vInstID);

      if (firstHit) {
        depth = min(depth, volumeDepth);
        primID = 0;
        objID = vObjID;
        instID = vInstID;
      }

      color *= opacity;

      const auto bg = getBackground(frameData.renderer, ss.screen);
      accumulateValue(color, vec3(bg), opacity);
      accumulateValue(opacity, bg.w, opacity);
      accumulateValue(outputColor, color, outputOpacity);
      accumulateValue(outputOpacity, opacity, outputOpacity);
      break;
    }
  }

  accumResults(frameData.fb,
      ss.pixel,
      vec4(outputColor, outputOpacity),
      depth,
      outputColor,
      outputNormal,
      primID,
      objID,
      instID);
}

} // namespace visrtx
