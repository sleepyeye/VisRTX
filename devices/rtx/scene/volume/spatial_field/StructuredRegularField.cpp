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

#include "StructuredRegularField.h"
// std
#include <algorithm>
#include <limits>
#include <vector>

namespace visrtx {

// Helper functions ///////////////////////////////////////////////////////////

template <typename FROM_T, typename TO_T = float>
static void convertElementsNormalized(
    const void *_begin, size_t size, TO_T *output)
{
  auto toFloatNormalized = [](auto c) {
    return TO_T(c / float(std::numeric_limits<FROM_T>::max()));
  };
  auto *begin = (const FROM_T *)_begin;
  std::transform(begin, begin + size, output, toFloatNormalized);
}

template <typename FROM_T, typename TO_T = float>
static void convertElements(const void *_begin, size_t size, TO_T *output)
{
  auto toFloat = [](auto c) { return TO_T(c); };
  auto *begin = (const FROM_T *)_begin;
  std::transform(begin, begin + size, output, toFloat);
}

static std::vector<float> makeFloatStagingBuffer(Array3D &array)
{
  const void *input = array.data();
  size_t size = array.totalSize();

  std::vector<float> stagingBuffer(size);

  ANARIDataType format = array.elementType();

  switch (format) {
  case ANARI_UINT8:
    convertElements<uint8_t>(input, size, stagingBuffer.data());
    break;
  case ANARI_INT16:
    convertElements<int16_t>(input, size, stagingBuffer.data());
    break;
  case ANARI_UINT16:
    convertElements<uint16_t>(input, size, stagingBuffer.data());
    break;
  case ANARI_UFIXED8:
    convertElementsNormalized<uint8_t>(input, size, stagingBuffer.data());
    break;
  case ANARI_FIXED16:
    convertElementsNormalized<int16_t>(input, size, stagingBuffer.data());
    break;
  case ANARI_UFIXED16:
    convertElementsNormalized<uint16_t>(input, size, stagingBuffer.data());
    break;
  case ANARI_FLOAT32:
    convertElements<float>(input, size, stagingBuffer.data());
    break;
  case ANARI_FLOAT64:
    convertElements<double>(input, size, stagingBuffer.data());
    break;
  default:
    break;
  }

  return stagingBuffer;
}

static bool validFieldDataType(ANARIDataType format)
{
  switch (format) {
  case ANARI_UINT8:
  case ANARI_INT16:
  case ANARI_UINT16:
  case ANARI_UFIXED8:
  case ANARI_FIXED16:
  case ANARI_UFIXED16:
  case ANARI_FLOAT32:
  case ANARI_FLOAT64:
    return true;
  default:
    break;
  }
  return false;
}

// StructuredRegularField definitions /////////////////////////////////////////

StructuredRegularField::StructuredRegularField(DeviceGlobalState *d)
    : SpatialField(d)
{}

StructuredRegularField::~StructuredRegularField()
{
  cleanup();
}

void StructuredRegularField::commit()
{
  cleanup();

  m_params.origin = getParam<vec3>("origin", vec3(0.f));
  m_params.spacing = getParam<vec3>("spacing", vec3(1.f));
  m_params.filter = getParamString("filter", "linear");
  m_params.data = getParamObject<Array3D>("data");

  if (!m_params.data) {
    reportMessage(ANARI_SEVERITY_WARNING,
        "missing required parameter 'data' on structuredRegular spatial field");
    return;
  }

  ANARIDataType format = m_params.data->elementType();

  if (!validFieldDataType(format)) {
    reportMessage(ANARI_SEVERITY_WARNING,
        "invalid data array type encountered "
        "in structuredRegular spatial field(%s)",
        anari::toString(format));
    return;
  }

  m_params.data->addCommitObserver(this);
  const auto dims = m_params.data->size();

  std::vector<float> stagingBuffer;
  if (format != ANARI_FLOAT32)
    stagingBuffer = makeFloatStagingBuffer(*m_params.data);

  auto desc = cudaCreateChannelDesc(
      sizeof(float) * 8, 0, 0, 0, cudaChannelFormatKindFloat);
  cudaMalloc3DArray(
      &m_cudaArray, &desc, make_cudaExtent(dims.x, dims.y, dims.z));

  cudaMemcpy3DParms copyParams;
  std::memset(&copyParams, 0, sizeof(copyParams));
  copyParams.srcPtr = make_cudaPitchedPtr(stagingBuffer.empty()
          ? const_cast<void *>(m_params.data->data())
          : stagingBuffer.data(),
      dims.x * sizeof(float),
      dims.x,
      dims.y);
  copyParams.dstArray = m_cudaArray;
  copyParams.extent = make_cudaExtent(dims.x, dims.y, dims.z);
  copyParams.kind = cudaMemcpyHostToDevice;

  cudaMemcpy3D(&copyParams);

  cudaResourceDesc resDesc;
  std::memset(&resDesc, 0, sizeof(resDesc));
  resDesc.resType = cudaResourceTypeArray;
  resDesc.res.array.array = m_cudaArray;

  cudaTextureDesc texDesc;
  std::memset(&texDesc, 0, sizeof(texDesc));
  texDesc.addressMode[0] = cudaAddressModeClamp;
  texDesc.addressMode[1] = cudaAddressModeClamp;
  texDesc.addressMode[2] = cudaAddressModeClamp;
  texDesc.filterMode =
      m_params.filter == "nearest" ? cudaFilterModePoint : cudaFilterModeLinear;
  texDesc.readMode = cudaReadModeElementType;
  texDesc.normalizedCoords = 1;

  cudaCreateTextureObject(&m_textureObject, &resDesc, &texDesc, nullptr);

  buildGrid();

  upload();
}

box3 StructuredRegularField::bounds() const
{
  if (!isValid())
    return {box3(vec3(0.f), vec3(1.f))};
  auto dims = m_params.data->size();
  return box3(m_params.origin,
      m_params.origin
          + ((vec3(dims.x, dims.y, dims.z) - 1.f) * m_params.spacing));
}

float StructuredRegularField::stepSize() const
{
  return glm::compMin(m_params.spacing / 2.f);
}

bool StructuredRegularField::isValid() const
{
  return m_params.data && validFieldDataType(m_params.data->elementType());
}

SpatialFieldGPUData StructuredRegularField::gpuData() const
{
  SpatialFieldGPUData sf;
  auto dims = m_params.data->size();
  sf.type = SpatialFieldType::STRUCTURED_REGULAR;
  sf.data.structuredRegular.texObj = m_textureObject;
  sf.data.structuredRegular.origin = m_params.origin;
  sf.data.structuredRegular.spacing = m_params.spacing;
  sf.data.structuredRegular.invSpacing =
      vec3(1.f) / (m_params.spacing * vec3(dims.x, dims.y, dims.z));
  sf.grid = m_uniformGrid.gpuData();
  return sf;
}

void StructuredRegularField::cleanup()
{
  if (m_textureObject)
    cudaDestroyTextureObject(m_textureObject);
  if (m_cudaArray)
    cudaFreeArray(m_cudaArray);
  m_textureObject = {};
  m_cudaArray = {};
  if (m_params.data)
    m_params.data->removeCommitObserver(this);
  m_uniformGrid.cleanup();
}

} // namespace visrtx
