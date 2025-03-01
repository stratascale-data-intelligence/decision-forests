#!/bin/bash
# Copyright 2021 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



# Build and test TF-DF.
# Options
#  RUN_TESTS: Run the unit tests e.g. 0 or 1.
#  PY_VERSION: Version of Python to be used, must be at least 3.7
#  STARTUP_FLAGS: Any flags given to bazel on startup
#  TF_VERSION: Tensorflow version to use or "nightly"
#
# Usage example
#
#   RUN_TESTS=1 PY_VERSION=3.8 TF_VERSION=2.10.0 ./tools/test_bazel.sh

set -vex

# Version of Python
# Needs to be >=python3.7
PYTHON=python${PY_VERSION}

# Install Pip dependencies
${PYTHON} -m ensurepip --upgrade || true
${PYTHON} -m pip install pip setuptools --upgrade
${PYTHON} -m pip install numpy pandas scikit-learn --upgrade

# Install Tensorflow at the chosen version.
if [ ${TF_VERSION} == "nightly" ]; then
  ${PYTHON} -m pip install tf-nightly --force-reinstall
else
  ${PYTHON} -m pip install tensorflow==${TF_VERSION} --force-reinstall
fi

echo -e "pip installed packages: \n"
pip list

# Get the commit SHA
short_commit_sha=$(python -c 'import tensorflow as tf; print(tf.__git_version__)' | tail -1 | grep -oP '(?<=-g)[0-9a-f]*$')
commit_sha=$(curl -SsL https://github.com/tensorflow/tensorflow/commit/${short_commit_sha} | grep sha-block | grep commit | sed -e 's/.*\([a-f0-9]\{40\}\).*/\1/')

# Update TF dependency to the chosen version
sed -i "s/strip_prefix = \"tensorflow-2\.[0-9]\+\.[0-9]\+\(-rc[0-9]\+\)\?\",/strip_prefix = \"tensorflow-${commit_sha}\",/" WORKSPACE
sed -i "s|\"https://github.com/tensorflow/tensorflow/archive/v.\+\.zip\"|\"https://github.com/tensorflow/tensorflow/archive/${commit_sha}.zip\"|" WORKSPACE
prev_shasum=$(grep -A 1 -e "strip_prefix.*tensorflow-" WORKSPACE | tail -1 | awk -F '"' '{print $2}')
sed -i "s/sha256 = \"${prev_shasum}\",//" WORKSPACE

# Get build configuration for chosen version.
TENSORFLOW_BAZELRC="tensorflow_bazelrc"
curl https://raw.githubusercontent.com/tensorflow/tensorflow/${commit_sha}/.bazelrc -o ${TENSORFLOW_BAZELRC}

# Force a compiler
# export CC=gcc-8
# export CXX=gcc-8

# Bazel common flags. Startup flags are already given through STARTUP_FLAGS
FLAGS=

# Detect the target host
PLATFORM="$(uname -s | tr 'A-Z' 'a-z')"

function is_windows() {
  # On windows, the shell script is actually running in msys
  [[ "${PLATFORM}" =~ msys_nt*|mingw*|cygwin*|uwin* ]]
}

function is_macos() {
  [[ "${PLATFORM}" == "darwin" ]]
}

if is_macos; then
  FLAGS="${FLAGS} --config=macos"
elif is_windows; then
  FLAGS="${FLAGS} --config=windows"
else
  FLAGS="${FLAGS} --config=linux"
fi

# Find the path to the pre-compiled version of TensorFlow installed in the
# "tensorflow" pip package.
TF_CFLAGS="$(${PYTHON} -c 'import tensorflow as tf; print(tf.sysconfig.get_compile_flags()[0])')"
TF_LFLAGS="$(${PYTHON} -c 'import tensorflow as tf; print(tf.sysconfig.get_link_flags()[0])')"

HEADER_DIR=${TF_CFLAGS:2}
if is_macos; then
  SHARED_LIBRARY_NAME="libtensorflow_framework.dylib"
  SHARED_LIBRARY_DIR=${TF_LFLAGS:2}
elif is_windows; then
 # Use pywrap_tensorflow's import library on Windows. It is in the same dir as the dll/pyd.
  SHARED_LIBRARY_NAME="_pywrap_tensorflow_internal.lib"
  SHARED_LIBRARY_DIR=${TF_CFLAGS:2:-7}"python"

  SHARED_LIBRARY_NAME=${SHARED_LIBRARY_NAME//\\//}
  SHARED_LIBRARY_DIR=${SHARED_LIBRARY_DIR//\\//}
  HEADER_DIR=${HEADER_DIR//\\//}
else
  SHARED_LIBRARY_DIR=${TF_LFLAGS:2}
  SHARED_LIBRARY_NAME="libtensorflow_framework.so.2"
fi

FLAGS="${FLAGS} --action_env TF_HEADER_DIR=${HEADER_DIR}"
FLAGS="${FLAGS} --action_env TF_SHARED_LIBRARY_DIR=${SHARED_LIBRARY_DIR}"
FLAGS="${FLAGS} --action_env TF_SHARED_LIBRARY_NAME=${SHARED_LIBRARY_NAME}"

# Bazel
BAZEL=bazel

STARTUP_FLAGS="${STARTUP_FLAGS} --bazelrc=${TENSORFLOW_BAZELRC}"

# Distributed compilation using Remote Build Execution (RBE)
#
# FLAGS="$FLAGS --config=rbe_cpu_linux --config=tensorflow_testing_rbe_linux --config=rbe_linux_py3"

# Minimal rules to create and test the Pip Package.
#
# Only require a small amount of TF to be compiled.
BUILD_RULES="//tensorflow_decision_forests/component/...:all //tensorflow_decision_forests/contrib/...:all //tensorflow_decision_forests/keras //tensorflow_decision_forests/keras:grpc_worker_main"
TEST_RULES="//tensorflow_decision_forests/component/...:all //tensorflow_decision_forests/contrib/...:all //tensorflow_decision_forests/keras/...:all"


# All the build rules.
#
# BUILD_RULES="//tensorflow_decision_forests/...:all"
# TEST_RULES="//tensorflow_decision_forests/...:all"

# Tests when distribution strategy is enabled.
# TEST_RULES="${TEST_RULES} //tensorflow_decision_forests/keras:keras_distributed_test"

# Build library
time ${BAZEL} ${STARTUP_FLAGS} build ${BUILD_RULES} ${FLAGS} --build_tag_filters=-tfdistributed

# Unit test library
if [ "${RUN_TESTS}" = 1 ]; then
  time ${BAZEL} ${STARTUP_FLAGS} test ${TEST_RULES} ${FLAGS} --test_size_filters=small,medium,large --test_tag_filters=-tfdistributed
fi

# Example of dependency check.
# ${BAZEL} --bazelrc=${TENSORFLOW_BAZELRC} cquery "somepath(//tensorflow_decision_forests/tensorflow/ops/inference:api_py,@org_tensorflow//tensorflow/c:kernels.cc)" ${FLAGS}
