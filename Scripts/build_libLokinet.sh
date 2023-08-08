#!/bin/bash

# XCode will error during it's dependency graph construction (which happens before the build
# stage starts and any target "Run Script" phases are triggered)
#
# In order to avoid this error we need to build the framework before actually getting to the
# build stage so XCode is able to build the dependency graph
#
# XCode's Pre-action scripts don't output anything into XCode so the only way to emit a useful
# error is to **return a success status** and have the project detect and log the error itself
# then log it, stopping the build at that point
#
# The other step to get this to work properly is to ensure the framework in "Link Binary with
# Libraries" isn't using a relative directory, unfortunately there doesn't seem to be a good
# way to do this directly so we need to modify the '.pbxproj' file directly, updating the
# framework entry to have the following (on a single line):
# {
#   isa = PBXFileReference;
#   explicitFileType = wrapper.xcframework;
#   includeInIndex = 0;
#   path = "{FRAMEWORK NAME GOES HERE}";
#   sourceTree = BUILD_DIR;
# };
#
# Note: We might one day be able to replace this with a local podspec if this GitHub feature
# request ever gets implemented: https://github.com/CocoaPods/CocoaPods/issues/8464

# Need to set the path or we won't find cmake
PATH=${PATH}:/usr/local/bin:/opt/homebrew/bin:/sbin/md5

exec 3>&1 # Save original stdout

# Ensure the build directory exists (in case we need it before XCode creates it)
mkdir -p "${TARGET_BUILD_DIR}/libLokinet"

# Remove any old build errors
rm -rf "${TARGET_BUILD_DIR}/libLokinet/liblokinet_output.log"

# Restore stdout and stderr and redirect it to the 'libsession_util_output.log' file
exec &> "${TARGET_BUILD_DIR}/libLokinet/liblokinet_output.log"

# Define a function to echo a message.
function echo_message() {
  exec 1>&3 # Restore stdout
  echo "$1"
  exec >> "${TARGET_BUILD_DIR}/libLokinet/liblokinet_output.log" # Redirect all output to the log file
}

echo_message "info: Validating build requirements"

set -x

# Ensure the build directory exists (in case we need it before XCode creates it)
mkdir -p "${TARGET_BUILD_DIR}"

if ! which cmake > /dev/null; then
  echo_message "error: cmake is required to build, please install (can install via homebrew with 'brew install cmake')."
  exit 0
fi

# Check if we have the `LibSession-Util` submodule checked out and if not (depending on the 'SHOULD_AUTO_INIT_SUBMODULES' argument) perform the checkout
if [ ! -d "${SRCROOT}/LibLokinet" ] || [ ! -d "${SRCROOT}/LibLokinet/llarp" ] || [ ! "$(ls -A "${SRCROOT}/LibLokinet")" ]; then
  echo_message "error: Need to fetch LibLokinet submodule (git submodule update --init --recursive)."
  exit 0
else
  are_submodules_valid() {
    local PARENT_PATH=$1
    local RELATIVE_PATH=$2
    
    # Change into the path to check for it's submodules
    cd "${PARENT_PATH}"
    local SUB_MODULE_PATHS=($(git config --file .gitmodules --get-regexp path | awk '{ print $2 }'))

    # If there are no submodules then return success based on whether the folder has any content
    if [ ${#SUB_MODULE_PATHS[@]} -eq 0 ]; then
      if [[ ! -z "$(ls -A "${PARENT_PATH}")" ]]; then
        return 0
      else
        return 1
      fi
    fi

    # Loop through the child submodules and check if they are valid
    for i in "${!SUB_MODULE_PATHS[@]}"; do
      local CHILD_PATH="${SUB_MODULE_PATHS[$i]}"
      
      # If the child path doesn't exist then it's invalid
      if [ ! -d "${PARENT_PATH}/${CHILD_PATH}" ]; then
        echo_message "info: Submodule '${RELATIVE_PATH}/${CHILD_PATH}' doesn't exist."
        return 1
      fi

      are_submodules_valid "${PARENT_PATH}/${CHILD_PATH}" "${RELATIVE_PATH}/${CHILD_PATH}"
      local RESULT=$?

      if [ "${RESULT}" -eq 1 ]; then
        echo_message "info: Submodule '${RELATIVE_PATH}/${CHILD_PATH}' is in an invalid state."
        return 1
      fi
    done

    return 0
  }

  # Validate the state of the submodules
  are_submodules_valid "${SRCROOT}/LibLokinet" "LibLokinet"

  HAS_INVALID_SUBMODULE=$?

  if [ "${HAS_INVALID_SUBMODULE}" -eq 1 ]; then
    echo_message "error: Submodules are in an invalid state, please delete 'LibLokinet' and run 'git submodule update --init --recursive'."
    exit 0
  fi
fi

# Generate a hash of the libSession-util source files and check if they differ from the last hash
echo "info: Checking for changes to source"

NEW_SOURCE_HASH=$(find "${SRCROOT}/LibLokinet/llarp" -type f -exec md5 {} + | awk '{print $NF}' | sort | md5 | awk '{print $NF}')
NEW_HEADER_HASH=$(find "${SRCROOT}/LibLokinet/include" -type f -exec md5 {} + | awk '{print $NF}' | sort | md5 | awk '{print $NF}')

if [ -f "${TARGET_BUILD_DIR}/libLokinet/liblokinet_source_hash.log" ]; then
    read -r OLD_SOURCE_HASH < "${TARGET_BUILD_DIR}/libLokinet/liblokinet_source_hash.log"
fi

if [ -f "${TARGET_BUILD_DIR}/libLokinet/liblokinet_header_hash.log" ]; then
    read -r OLD_HEADER_HASH < "${TARGET_BUILD_DIR}/libLokinet/liblokinet_header_hash.log"
fi

if [ -f "${TARGET_BUILD_DIR}/libLokinet/liblokinet_archs.log" ]; then
    read -r OLD_ARCHS < "${TARGET_BUILD_DIR}/libLokinet/liblokinet_archs.log"
fi

# If all of the hashes match, the archs match and there is a library file then we can just stop here
if [ "${NEW_SOURCE_HASH}" == "${OLD_SOURCE_HASH}" ] && [ "${NEW_HEADER_HASH}" == "${OLD_HEADER_HASH}" ] && [ "${ARCHS[*]}" == "${OLD_ARCHS}" ] && [ -f "${TARGET_BUILD_DIR}/libLokinet/libLokinet.a" ]; then
  echo_message "info: Build is up-to-date"
  exit 0
fi

# If any of the above differ then we need to rebuild
echo_message "info: Build is not up-to-date - creating new build"

# Import settings from XCode (defaulting values if not present)
VALID_SIM_ARCHS=(arm64 x86_64)
VALID_DEVICE_ARCHS=(arm64)
VALID_SIM_ARCH_PLATFORMS=(SIMULATORARM64 SIMULATOR64)
VALID_DEVICE_ARCH_PLATFORMS=(OS64)

OUTPUT_DIR="${TARGET_BUILD_DIR}"
IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET}
ENABLE_BITCODE=${ENABLE_BITCODE}

# Generate the target architectures we want to build for
TARGET_ARCHS=()
TARGET_PLATFORMS=()
TARGET_SIM_ARCHS=()
TARGET_DEVICE_ARCHS=()

if [ -z $PLATFORM_NAME ] || [ $PLATFORM_NAME = "iphonesimulator" ]; then
    for i in "${!VALID_SIM_ARCHS[@]}"; do
        ARCH="${VALID_SIM_ARCHS[$i]}"
        ARCH_PLATFORM="${VALID_SIM_ARCH_PLATFORMS[$i]}"

        if [[ " ${ARCHS[*]} " =~ " ${ARCH} " ]]; then
            TARGET_ARCHS+=("sim-${ARCH}")
            TARGET_PLATFORMS+=("${ARCH_PLATFORM}")
            TARGET_SIM_ARCHS+=("sim-${ARCH}")
        fi
    done
fi

if [ -z $PLATFORM_NAME ] || [ $PLATFORM_NAME = "iphoneos" ]; then
    for i in "${!VALID_DEVICE_ARCHS[@]}"; do
        ARCH="${VALID_DEVICE_ARCHS[$i]}"
        ARCH_PLATFORM="${VALID_DEVICE_ARCH_PLATFORMS[$i]}"

        if [[ " ${ARCHS[*]} " =~ " ${ARCH} " ]]; then
            TARGET_ARCHS+=("ios-${ARCH}")
            TARGET_PLATFORMS+=("${ARCH_PLATFORM}")
            TARGET_DEVICE_ARCHS+=("ios-${ARCH}")
        fi
    done
fi

# Create a function to procses and log errors
process_and_log_errors() {
  cp "${TARGET_BUILD_DIR}/libLokinet/liblokinet_output.log" "${TARGET_BUILD_DIR}/libLokinet/tmp_liblokinet_output.log"
  local ALL_CMAKE_ERROR_LINES=($(grep -n -i "CMake Error" "${TARGET_BUILD_DIR}/libLokinet/tmp_liblokinet_output.log" | cut -d ":" -f 1))
  local ALL_ERROR_LINES=($(grep -n -i "error:" "${TARGET_BUILD_DIR}/libLokinet/tmp_liblokinet_output.log" | cut -d ":" -f 1))

  for e in "${!ALL_CMAKE_ERROR_LINES[@]}"; do
    local error_line="${ALL_CMAKE_ERROR_LINES[$e]}"
    local actual_error_line=$((error_line + 1))
    local error=$(sed "${error_line}q;d" "${TARGET_BUILD_DIR}/libLokinet/tmp_liblokinet_output.log")
    local error="${error}$(sed "${actual_error_line}q;d" "${TARGET_BUILD_DIR}/libLokinet/tmp_liblokinet_output.log")"

    # Exclude the 'ALL_ERROR_LINES' line and the 'grep' line
    if [[ ! $error == *'grep -n -i "CMake Error"'* ]] && [[ ! $error == *"grep -n -i 'CMake Error'"* ]] && [[ ! $error == *'grep -n -i CMake Error'* ]]; then
        echo_message "error: $error"
    fi
  done

  for e in "${!ALL_ERROR_LINES[@]}"; do
    local error_line="${ALL_ERROR_LINES[$e]}"
    local error=$(sed "${error_line}q;d" "${TARGET_BUILD_DIR}/libLokinet/tmp_liblokinet_output.log")

    # Exclude the 'ALL_ERROR_LINES' line and the 'grep' line (the 'system_error:' one is a swift file)
    if [[ ! $error == *'grep -n -i "error:"'* ]] && [[ ! $error == *'grep -n -i error:'* ]] && [[ ! $error == *'system_error:'* ]]; then
        echo_message "error: $error"
    fi
  done

  rm -f "${TARGET_BUILD_DIR}/libLokinet/tmp_liblokinet_output.log"
}

# Build the individual architectures
for i in "${!TARGET_ARCHS[@]}"; do
    build="${TARGET_BUILD_DIR}/libLokinet/${TARGET_ARCHS[$i]}"
    platform="${TARGET_PLATFORMS[$i]}"
    echo_message "Building ${TARGET_ARCHS[$i]} for $platform in $build"

    cd "${SRCROOT}/LibLokinet"

    # Configure the build
    ./contrib/ios/ios-configure.sh "$build" ${platform} $@

    # If an error occurred during config then process it and stop
    if [ $? -ne 0 ]; then
      process_and_log_errors
      exit 1
    fi

    # Build
    ./contrib/ios/ios-build.sh "$build"
    
    # If an error occurred during building then process it and stop
    if [ $? -ne 0 ]; then
      process_and_log_errors
      exit 1
    fi
done

# Remove the old static library file
rm -rf "${TARGET_BUILD_DIR}/libLokinet/libLokinet.a"
rm -rf "${TARGET_BUILD_DIR}/libLokinet/Headers"

# If needed combine simulator builds into a multi-arch lib
if [ "${#TARGET_SIM_ARCHS[@]}" -eq "1" ]; then
    # Single device build
    cp "${TARGET_BUILD_DIR}/libLokinet/${TARGET_SIM_ARCHS[0]}/llarp/liblokinet-embedded.a" "${TARGET_BUILD_DIR}/libLokinet/libLokinet.a"
elif [ "${#TARGET_SIM_ARCHS[@]}" -gt "1" ]; then
    # Combine multiple device builds into a multi-arch lib
    echo_message "info: Built multiple architectures, merging into single static library"
    lipo -create "${TARGET_BUILD_DIR}/libLokinet"/sim-*/llarp/liblokinet-embedded.a -output "${TARGET_BUILD_DIR}/libLokinet/libLokinet.a"
fi

# If needed combine device builds into a multi-arch lib
if [ "${#TARGET_DEVICE_ARCHS[@]}" -eq "1" ]; then
    cp "${TARGET_BUILD_DIR}/libLokinet/${TARGET_DEVICE_ARCHS[0]}/liblokinet-embedded.a" "${TARGET_BUILD_DIR}/libLokinet/libLokinet.a"
elif [ "${#TARGET_DEVICE_ARCHS[@]}" -gt "1" ]; then
    # Combine multiple device builds into a multi-arch lib
    echo_message "info: Built multiple architectures, merging into single static library"
    lipo -create "${TARGET_BUILD_DIR}/libLokinet"/ios-*/llarp/liblokinet-embedded.a -output "${TARGET_BUILD_DIR}/libLokinet/libLokinet.a"
fi

# Save the updated hashes to disk to prevent rebuilds when there were no changes
echo "${NEW_SOURCE_HASH}" > "${TARGET_BUILD_DIR}/libLokinet/liblokinet_source_hash.log"
echo "${NEW_HEADER_HASH}" > "${TARGET_BUILD_DIR}/libLokinet/liblokinet_header_hash.log"
echo "${ARCHS[*]}" > "${TARGET_BUILD_DIR}/libLokinet/liblokinet_archs.log"
echo_message "info: Build complete"

# Copy the headers across
echo_message "info: Copy headers and prepare modulemap"
mkdir -p "${TARGET_BUILD_DIR}/libLokinet/Headers"
cp -r "${SRCROOT}/LibLokinet/include" "${TARGET_BUILD_DIR}/libLokinet/Headers"

# The 'module.modulemap' is needed for XCode to be able to find the headers
modmap="${TARGET_BUILD_DIR}/libLokinet/Headers/module.modulemap"
echo "module libLokinet {" >"$modmap"
echo "  module capi {" >>"$modmap"
echo "    header \"include/lokinet.h\"" >>"$modmap"
echo "    export *" >> "$modmap"
echo "  }" >> "$modmap"
echo "}" >> "$modmap"

# Output to XCode just so the output is good
echo_message "info: libLokinet Ready"