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

#include "TransferFunction1D.h"
#include "utility/colorMapHelpers.h"

namespace visrtx {

TransferFunction1D::TransferFunction1D(DeviceGlobalState *d) : Volume(d) {}

TransferFunction1D::~TransferFunction1D()
{
  cleanup();
}

void TransferFunction1D::commit()
{
  Volume::commit();

  cleanup();

  m_params.color = getParamObject<Array1D>("color");
  m_params.colorPosition = getParamObject<Array1D>("color.position");
  m_params.opacity = getParamObject<Array1D>("opacity");
  m_params.opacityPosition = getParamObject<Array1D>("opacity.position");
  m_params.densityScale = getParam<float>("densityScale", 1.f);
  m_params.field = getParamObject<SpatialField>("field");

  {
    auto valueRangeAsVec2 = getParam<vec2>("valueRange", vec2(0.f, 1.f));
    m_params.valueRange =
        getParam<box1>("valueRange", make_box1(valueRangeAsVec2));
  }

  if (!m_params.field) {
    reportMessage(ANARI_SEVERITY_WARNING,
        "missing parameter 'field' on transferFunction1D ANARIVolume");
    return;
  }

  if (!m_params.color) {
    reportMessage(ANARI_SEVERITY_WARNING,
        "missing parameter 'color' on transferFunction1D ANARIVolume");
    return;
  }

  if (!m_params.opacity) {
    reportMessage(ANARI_SEVERITY_WARNING,
        "missing parameter 'opacity' on transferFunction1D ANARIVolume");
    return;
  }

  if (m_params.colorPosition
      && m_params.color->totalSize() != m_params.colorPosition->totalSize()) {
    reportMessage(ANARI_SEVERITY_ERROR,
        "TransferFunction1D 'color' and 'color.position'"
        " arrays are of different size");
    return;
  }

  if (m_params.opacityPosition
      && m_params.opacity->totalSize()
          != m_params.opacityPosition->totalSize()) {
    reportMessage(ANARI_SEVERITY_ERROR,
        "TransferFunction1D 'opacity' and 'opacity.position'"
        " arrays are of different size");
    return;
  }

  m_params.field->addCommitObserver(this);
  m_params.color->addCommitObserver(this);
  m_params.opacity->addCommitObserver(this);
  if (m_params.colorPosition)
    m_params.colorPosition->addCommitObserver(this);
  if (m_params.opacityPosition)
    m_params.opacityPosition->addCommitObserver(this);

  discritizeTFData();

  auto desc = cudaCreateChannelDesc(32, 32, 32, 32, cudaChannelFormatKindFloat);
  cudaMallocArray(&m_cudaArray, &desc, m_tfDim);

  cudaMemcpy3DParms copyParams;
  std::memset(&copyParams, 0, sizeof(copyParams));
  copyParams.srcPtr =
      make_cudaPitchedPtr(m_tf.data(), m_tfDim * sizeof(vec4), m_tfDim, 0);
  copyParams.dstArray = m_cudaArray;
  copyParams.extent = make_cudaExtent(m_tfDim, 1, 1);
  copyParams.kind = cudaMemcpyHostToDevice;

  cudaMemcpy3D(&copyParams);

  cudaResourceDesc resDesc;
  std::memset(&resDesc, 0, sizeof(resDesc));
  resDesc.resType = cudaResourceTypeArray;
  resDesc.res.array.array = m_cudaArray;

  cudaTextureDesc texDesc;
  std::memset(&texDesc, 0, sizeof(texDesc));
  texDesc.addressMode[0] = cudaAddressModeClamp;
  texDesc.filterMode = cudaFilterModeLinear;
  texDesc.readMode = cudaReadModeElementType;
  texDesc.normalizedCoords = 1;

  cudaCreateTextureObject(&m_textureObject, &resDesc, &texDesc, nullptr);

  if (m_params.field->isValid()) {
    m_params.field->m_uniformGrid.computeMaxOpacities(
        deviceState()->stream, m_textureObject, m_tfDim);
  }

  upload();
}

bool TransferFunction1D::isValid() const
{
  return m_params.color && m_params.opacity && m_params.field
      && m_params.field->isValid();
}

VolumeGPUData TransferFunction1D::gpuData() const
{
  VolumeGPUData retval = Volume::gpuData();
  retval.type = VolumeType::SCIVIS;
  retval.bounds = m_params.field->bounds();
  retval.stepSize = m_params.field->stepSize();
  retval.data.scivis.tfTex = m_textureObject;
  retval.data.scivis.valueRange = m_params.valueRange;
  retval.data.scivis.densityScale = m_params.densityScale;
  retval.data.scivis.field = m_params.field->index();
  return retval;
}

void TransferFunction1D::discritizeTFData()
{
  m_tf.resize(m_tfDim);

  Span<float> cPositions;
  Span<float> oPositions;

  std::vector<float> linearColorPositions;
  std::vector<float> linearOpacityPositions;

  if (m_params.colorPosition) {
    cPositions = make_Span(m_params.colorPosition->beginAs<float>(),
        m_params.colorPosition->size());
  } else {
    linearColorPositions = generateLinearPositions(
        m_params.color->totalSize(), m_params.valueRange);
    cPositions =
        make_Span(linearColorPositions.data(), linearColorPositions.size());
  }

  if (m_params.colorPosition) {
    oPositions = make_Span(m_params.opacityPosition->beginAs<float>(),
        m_params.opacityPosition->size());
  } else {
    linearOpacityPositions = generateLinearPositions(
        m_params.opacity->totalSize(), m_params.valueRange);
    oPositions =
        make_Span(linearOpacityPositions.data(), linearOpacityPositions.size());
  }

  for (size_t i = 0; i < m_tf.size(); i++) {
    const float p = float(i) / (m_tf.size() - 1);
    const auto c = getInterpolatedValue(
        m_params.color->beginAs<vec3>(), cPositions, m_params.valueRange, p);
    const auto o = getInterpolatedValue(
        m_params.opacity->beginAs<float>(), oPositions, m_params.valueRange, p);
    m_tf[i] = vec4(c, o);
  }
}

void TransferFunction1D::cleanup()
{
  if (m_textureObject)
    cudaDestroyTextureObject(m_textureObject);
  if (m_cudaArray)
    cudaFreeArray(m_cudaArray);
  m_textureObject = {};
  m_cudaArray = {};
  if (m_params.field)
    m_params.field->removeCommitObserver(this);
  if (m_params.color)
    m_params.color->removeCommitObserver(this);
  if (m_params.colorPosition)
    m_params.colorPosition->removeCommitObserver(this);
  if (m_params.opacity)
    m_params.opacity->removeCommitObserver(this);
  if (m_params.opacityPosition)
    m_params.opacityPosition->removeCommitObserver(this);
}

} // namespace visrtx
