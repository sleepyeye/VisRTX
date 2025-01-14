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

#include "Frame.h"
#include "utility/instrument.h"
// std
#include <algorithm>
#include <atomic>
#include <random>
// thrust
#include <thrust/fill.h>
#include <thrust/transform.h>

namespace visrtx {

// Frame definitions //////////////////////////////////////////////////////////

static std::atomic<size_t> s_numFrames = 0;

size_t Frame::objectCount()
{
  return s_numFrames;
}

Frame::Frame(DeviceGlobalState *d) : helium::BaseFrame(d), m_denoiser(d)
{
  s_numFrames++;
  cudaEventCreate(&m_eventStart);
  cudaEventCreate(&m_eventEnd);

  cudaEventRecord(m_eventStart, d->stream);
  cudaEventRecord(m_eventEnd, d->stream);
}

Frame::~Frame()
{
  wait();

  cudaEventDestroy(m_eventStart);
  cudaEventDestroy(m_eventEnd);
  s_numFrames--;
}

bool Frame::isValid() const
{
  return m_valid;
}

DeviceGlobalState *Frame::deviceState() const
{
  return (DeviceGlobalState *)helium::BaseObject::m_state;
}

void Frame::commit()
{
  auto &hd = data();

  m_renderer = getParamObject<Renderer>("renderer");
  if (!m_renderer) {
    reportMessage(ANARI_SEVERITY_WARNING,
        "missing required parameter 'renderer' on frame");
  }

  m_camera = getParamObject<Camera>("camera");
  if (!m_camera) {
    reportMessage(
        ANARI_SEVERITY_WARNING, "missing required parameter 'camera' on frame");
  }

  m_world = getParamObject<World>("world");
  if (!m_world) {
    reportMessage(
        ANARI_SEVERITY_WARNING, "missing required parameter 'world' on frame");
  }

  m_valid = m_renderer && m_renderer->isValid() && m_camera
      && m_camera->isValid() && m_world && m_world->isValid();

  if (!m_valid)
    return;

  auto format =
      getParam<ANARIDataType>("channel.color", ANARI_UFIXED8_RGBA_SRGB);
  const bool useFloatFB = m_denoise || format == ANARI_FLOAT32_VEC4;
  if (useFloatFB)
    hd.fb.format = FrameFormat::FLOAT;
  else if (format == ANARI_UFIXED8_RGBA_SRGB)
    hd.fb.format = FrameFormat::SRGB;
  else
    hd.fb.format = FrameFormat::UINT;

  m_colorType = format;

  hd.fb.size = getParam<uvec2>("size", uvec2(10));
  hd.fb.invSize = 1.f / vec2(hd.fb.size);

  m_depthType = getParam<ANARIDataType>("channel.depth", ANARI_UNKNOWN);
  m_primIDType = getParam<ANARIDataType>("channel.primitiveId", ANARI_UNKNOWN);
  m_objIDType = getParam<ANARIDataType>("channel.objectId", ANARI_UNKNOWN);
  m_instIDType = getParam<ANARIDataType>("channel.instanceId", ANARI_UNKNOWN);
  m_albedoType = getParam<ANARIDataType>("channel.albedo", ANARI_UNKNOWN);
  m_normalType = getParam<ANARIDataType>("channel.normal", ANARI_UNKNOWN);

  const bool channelPrimID = m_primIDType == ANARI_UINT32;
  const bool channelObjID = m_objIDType == ANARI_UINT32;
  const bool channelInstID = m_instIDType == ANARI_UINT32;
  const bool channelAlbedo = m_albedoType == ANARI_FLOAT32;
  const bool channelNormal = m_normalType == ANARI_FLOAT32;

  const bool channelDepth = m_depthType == ANARI_FLOAT32 || channelPrimID
      || channelObjID || channelInstID;
  if (channelDepth && m_depthType != ANARI_FLOAT32)
    m_depthType = ANARI_FLOAT32;

  const auto numPixels = hd.fb.size.x * hd.fb.size.y;

  m_accumColor.resize(numPixels);
  m_perPixelBytes = 4 * (useFloatFB ? 4 : 1);
  m_pixelBuffer.resize(numPixels * m_perPixelBytes);

  m_depthBuffer.resize(channelDepth ? numPixels : 0);
  m_primIDBuffer.resize(channelPrimID ? numPixels : 0);
  m_objIDBuffer.resize(channelObjID ? numPixels : 0);
  m_instIDBuffer.resize(channelInstID ? numPixels : 0);

  m_accumAlbedo.resize(channelAlbedo ? numPixels : 0);
  m_deviceAlbedoBuffer.resize(channelAlbedo ? numPixels : 0);
  m_mappedAlbedoBuffer.resize(channelAlbedo ? numPixels : 0);

  m_accumNormal.resize(channelNormal ? numPixels : 0);
  m_deviceNormalBuffer.resize(channelNormal ? numPixels : 0);
  m_mappedNormalBuffer.resize(channelNormal ? numPixels : 0);

  hd.fb.buffers.colorAccumulation =
      thrust::raw_pointer_cast(m_accumColor.data());

  hd.fb.buffers.outColorVec4 = nullptr;
  hd.fb.buffers.outColorUint = nullptr;

  if (useFloatFB)
    hd.fb.buffers.outColorVec4 = (vec4 *)m_pixelBuffer.dataDevice();
  else
    hd.fb.buffers.outColorUint = (uint32_t *)m_pixelBuffer.dataDevice();

  hd.fb.buffers.depth = channelDepth ? m_depthBuffer.dataDevice() : nullptr;
  hd.fb.buffers.primID = channelPrimID ? m_primIDBuffer.dataDevice() : nullptr;
  hd.fb.buffers.objID = channelObjID ? m_objIDBuffer.dataDevice() : nullptr;
  hd.fb.buffers.instID = channelInstID ? m_instIDBuffer.dataDevice() : nullptr;
  hd.fb.buffers.albedo =
      channelAlbedo ? thrust::raw_pointer_cast(m_accumAlbedo.data()) : nullptr;
  hd.fb.buffers.normal =
      channelNormal ? thrust::raw_pointer_cast(m_accumNormal.data()) : nullptr;

  if (m_denoise)
    m_denoiser.setup(hd.fb.size, m_pixelBuffer, format);
  else
    m_denoiser.cleanup();

  m_frameChanged = true;
}

bool Frame::getProperty(
    const std::string_view &name, ANARIDataType type, void *ptr, uint32_t flags)
{
  if (type == ANARI_FLOAT32 && name == "duration") {
    if (flags & ANARI_WAIT)
      wait();
    cudaEventElapsedTime(&m_duration, m_eventStart, m_eventEnd);
    m_duration /= 1000;
    helium::writeToVoidP(ptr, m_duration);
    return true;
  } else if (type == ANARI_INT32 && name == "numSamples") {
    if (flags & ANARI_WAIT)
      wait();
    auto &hd = data();
    helium::writeToVoidP(ptr, hd.fb.frameID);
    return true;
  } else if (type == ANARI_BOOL && name == "nextFrameReset") {
    if (flags & ANARI_WAIT)
      wait();
    if (ready())
      deviceState()->commitBufferFlush();
    checkAccumulationReset();
    helium::writeToVoidP(ptr, m_nextFrameReset);
    return true;
  }

  return 0;
}

void Frame::renderFrame()
{
  wait();

  auto &state = *deviceState();

  instrument::rangePush("update scene");
  instrument::rangePush("flush commits");
  state.commitBufferFlush();
  instrument::rangePop(); // flush commits

  instrument::rangePush("flush array uploads");
  state.uploadBuffer.flush();
  instrument::rangePop(); // flush array uploads

  instrument::rangePush("rebuild BVHs");
  m_world->rebuildBVHs();
  instrument::rangePop(); // rebuild BVHs
  instrument::rangePop(); // update scene

  if (!isValid()) {
    reportMessage(ANARI_SEVERITY_ERROR,
        "skipping render of incomplete or invalid frame object");
    return;
  }

  bool wasDenoising = m_denoise;
  m_denoise = m_renderer->denoise();
  if (m_denoise != wasDenoising)
    this->commit();

  m_frameMappedOnce = false;

  instrument::rangePush("frame + map");
  instrument::rangePush("Frame::renderFrame()");
  instrument::rangePush("frame setup");

  checkAccumulationReset();

  auto &hd = data();

  const int sampleLimit = m_renderer->sampleLimit();
  if (!m_nextFrameReset && sampleLimit > 0 && hd.fb.frameID >= sampleLimit)
    return;

  cudaEventRecord(m_eventStart, state.stream);

  m_renderer->populateFrameData(hd);

  hd.camera = (CameraGPUData *)m_camera->deviceData();

  hd.world.surfaceInstances = m_world->instanceSurfaceGPUData().data();
  hd.world.numSurfaceInstances = m_world->instanceSurfaceGPUData().size();
  hd.world.surfacesTraversable = m_world->optixTraversableHandleSurfaces();

  hd.world.volumeInstances = m_world->instanceVolumeGPUData().data();
  hd.world.numVolumeInstances = m_world->instanceVolumeGPUData().size();
  hd.world.volumesTraversable = m_world->optixTraversableHandleVolumes();

  hd.world.lightInstances = m_world->instanceLightGPUData().data();
  hd.world.numLightInstances = m_world->instanceLightGPUData().size();

  hd.registry.samplers = state.registry.samplers.devicePtr();
  hd.registry.geometries = state.registry.geometries.devicePtr();
  hd.registry.materials = state.registry.materials.devicePtr();
  hd.registry.surfaces = state.registry.surfaces.devicePtr();
  hd.registry.lights = state.registry.lights.devicePtr();
  hd.registry.fields = state.registry.fields.devicePtr();
  hd.registry.volumes = state.registry.volumes.devicePtr();

  const int spp = std::max(m_renderer->spp(), 1);

  instrument::rangePop(); // frame setup
  instrument::rangePush("render all frames");

  for (int i = 0; i < spp; i++) {
    instrument::rangePush("Frame::newFrame()");
    newFrame();
    instrument::rangePop(); // Frame::newFrame()

    instrument::rangePush("Frame::upload()");
    upload();
    instrument::rangePop(); // Frame::upload()

    instrument::rangePush("optixLaunch()");
    OPTIX_CHECK(optixLaunch(m_renderer->pipeline(),
        state.stream,
        (CUdeviceptr)deviceData(),
        payloadBytes(),
        m_renderer->sbt(),
        checkerboarding() ? (hd.fb.size.x + 1) / 2 : hd.fb.size.x,
        checkerboarding() ? (hd.fb.size.y + 1) / 2 : hd.fb.size.y,
        1));
    instrument::rangePop(); // optixLaunch()
  }

  if (m_denoise)
    m_denoiser.launch();

  instrument::rangePop(); // render all frames
  cudaEventRecord(m_eventEnd, state.stream);
  instrument::rangePop(); // Frame::renderFrame()
  instrument::rangePush("time until FB map");
}

void *Frame::map(std::string_view channel,
    uint32_t *width,
    uint32_t *height,
    ANARIDataType *pixelType)
{
  wait();

  ANARIDataType type = ANARI_UNKNOWN;
  void *retval = nullptr;

  const bool channelDepth = m_depthType == ANARI_FLOAT32;
  const bool channelPrimID = m_primIDType == ANARI_UINT32;
  const bool channelObjID = m_objIDType == ANARI_UINT32;
  const bool channelInstID = m_instIDType == ANARI_UINT32;
  const bool channelAlbedo = m_albedoType == ANARI_FLOAT32;
  const bool channelNormal = m_normalType == ANARI_FLOAT32;

  if (channel == "channel.color") {
    type = m_colorType;
    retval = mapColorBuffer();
  } else if (channel == "channel.colorGPU") {
    type = m_colorType;
    retval = mapGPUColorBuffer();
  } else if (channelDepth && channel == "channel.depth") {
    type = ANARI_FLOAT32;
    retval = mapDepthBuffer();
  } else if (channelDepth && channel == "channel.depthGPU") {
    type = ANARI_FLOAT32;
    retval = mapGPUDepthBuffer();
  } else if (channelPrimID && channel == "channel.primitiveId") {
    type = ANARI_UINT32;
    retval = mapPrimIDBuffer();
  } else if (channelObjID && channel == "channel.objectId") {
    type = ANARI_UINT32;
    retval = mapObjIDBuffer();
  } else if (channelInstID && channel == "channel.instanceId") {
    type = ANARI_UINT32;
    retval = mapInstIDBuffer();
  } else if (channelNormal && channel == "channel.normal") {
    type = ANARI_FLOAT32_VEC3;
    retval = mapNormalBuffer();
  } else if (channelAlbedo && channel == "channel.albedo") {
    type = ANARI_FLOAT32_VEC3;
    retval = mapAlbedoBuffer();
  }

  if (type != ANARI_UNKNOWN) {
    const auto &hd = data();
    *width = hd.fb.size.x;
    *height = hd.fb.size.y;
  }

  *pixelType = type;

  return retval;
}

void Frame::unmap(std::string_view channel)
{
  // no-op
}

int Frame::frameReady(ANARIWaitMask m)
{
  if (m == ANARI_NO_WAIT)
    return ready();
  else {
    wait();
    return 1;
  }
}

void Frame::discard()
{
  // no-op
}

void *Frame::mapColorBuffer()
{
  void *retval = nullptr;

  if (!m_frameMappedOnce)
    instrument::rangePop(); // time until FB map

  instrument::rangePush("copy to host");

  if (m_denoise)
    retval = m_denoiser.mapColorBuffer();
  else {
    m_pixelBuffer.download();
    retval = m_pixelBuffer.dataHost();
  }

  instrument::rangePop(); // copy to host

  if (!m_frameMappedOnce)
    instrument::rangePop(); // frame + map

  m_frameMappedOnce = true;

  return retval;
}

void *Frame::mapGPUColorBuffer()
{
  if (!m_frameMappedOnce) {
    instrument::rangePop(); // time until FB map
    instrument::rangePop(); // frame + map
  }

  m_frameMappedOnce = true;

  return m_denoise ? m_denoiser.mapGPUColorBuffer()
                   : m_pixelBuffer.dataDevice();
}

void *Frame::mapDepthBuffer()
{
  m_depthBuffer.download();
  m_frameMappedOnce = true;
  return m_depthBuffer.dataHost();
}

void *Frame::mapGPUDepthBuffer()
{
  m_frameMappedOnce = true;
  return m_depthBuffer.dataDevice();
}

void *Frame::mapPrimIDBuffer()
{
  m_primIDBuffer.download();
  m_frameMappedOnce = true;
  return m_primIDBuffer.dataHost();
}

void *Frame::mapObjIDBuffer()
{
  m_objIDBuffer.download();
  m_frameMappedOnce = true;
  return m_objIDBuffer.dataHost();
}

void *Frame::mapInstIDBuffer()
{
  m_instIDBuffer.download();
  m_frameMappedOnce = true;
  return m_instIDBuffer.dataHost();
}

void *Frame::mapAlbedoBuffer()
{
  auto &state = *deviceState();
  const float invFrameID = m_invFrameID;
  thrust::transform(thrust::cuda::par.on(state.stream),
      m_accumAlbedo.begin(),
      m_accumAlbedo.end(),
      m_deviceAlbedoBuffer.begin(),
      [=] __device__(const vec3 &in) { return in * invFrameID; });
  m_mappedAlbedoBuffer = m_deviceAlbedoBuffer;
  m_frameMappedOnce = true;
  return m_mappedAlbedoBuffer.data();
}

void *Frame::mapNormalBuffer()
{
  auto &state = *deviceState();
  const float invFrameID = m_invFrameID;
  thrust::transform(thrust::cuda::par.on(state.stream),
      m_accumNormal.begin(),
      m_accumNormal.end(),
      m_deviceNormalBuffer.begin(),
      [=] __device__(const vec3 &in) { return in * invFrameID; });
  m_mappedNormalBuffer = m_deviceNormalBuffer;
  m_frameMappedOnce = true;
  return m_mappedNormalBuffer.data();
}

bool Frame::ready() const
{
  return cudaEventQuery(m_eventEnd) == cudaSuccess;
}

void Frame::wait() const
{
  cudaEventSynchronize(m_eventEnd);
}

bool Frame::checkerboarding() const
{
  return m_renderer ? m_renderer->checkerboarding() : false;
}

void Frame::checkAccumulationReset()
{
  if (m_nextFrameReset)
    return;

  auto &state = *deviceState();
  if (m_lastCommitOccured < state.commitBufferLastFlush()) {
    m_lastCommitOccured = state.commitBufferLastFlush();
    m_nextFrameReset = true;
  }
  if (m_lastUploadOccured < state.uploadBuffer.lastFlush()) {
    m_lastUploadOccured = state.uploadBuffer.lastFlush();
    m_nextFrameReset = true;
  }
}

void Frame::newFrame()
{
  auto &hd = data();
  if (m_nextFrameReset) {
    hd.fb.frameID = 0;
    hd.fb.checkerboardID = checkerboarding() ? 0 : -1;
    m_nextFrameReset = false;
  } else {
    hd.fb.frameID += (!checkerboarding() || hd.fb.checkerboardID == 3);
    hd.fb.checkerboardID =
        checkerboarding() ? ((hd.fb.checkerboardID + 1) & 0x3) : -1;
  }

  hd.fb.invFrameID = m_invFrameID = 1.f / (hd.fb.frameID + 1);
  m_frameChanged = false;
}

} // namespace visrtx

VISRTX_ANARI_TYPEFOR_DEFINITION(visrtx::Frame *);
