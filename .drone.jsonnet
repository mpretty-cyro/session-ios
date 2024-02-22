// This build configuration requires the following to be installed:
// Git, Xcode, XCode Command-line Tools, Cocoapods, Xcodebuild, Xcresultparser, pip

// Log a bunch of version information to make it easier for debugging
local version_info = {
  name: 'Version Information',
  commands: [
    'git --version',
    'pod --version',
    'xcodebuild -version'
  ]
};

// Intentionally doing a depth of 2 as libSession-util has it's own submodules (and libLokinet likely will as well)
local clone_submodules = {
  name: 'Clone Submodules',
  commands: ['git fetch --tags', 'git submodule update --init --recursive --depth=2 --jobs=4']
};

// cmake options for static deps mirror
local ci_dep_mirror(want_mirror) = (if want_mirror then ' -DLOCAL_MIRROR=https://oxen.rocks/deps ' else '');

// Cocoapods
// 
// Unfortunately Cocoapods has a dumb restriction which requires you to use UTF-8 for the
// 'LANG' env var so we need to work around the with https://github.com/CocoaPods/CocoaPods/issues/6333
local install_cocoapods = {
  name: 'Install CocoaPods',
  commands: ['
    LANG=en_US.UTF-8 pod install || rm -rf ./Pods && LANG=en_US.UTF-8 pod install
  '],
  depends_on: [
    'Load CocoaPods Cache'
  ]
};

// Load from the cached CocoaPods directory (to speed up the build)
local load_cocoapods_cache = {
  name: 'Load CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/drone/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/drone/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/drone/.cocoapods_cache.lock',
    |||
      if [[ -d /Users/drone/.cocoapods_cache ]]; then
        cp -r /Users/drone/.cocoapods_cache ./Pods
      fi
    |||,
    'rm -f /Users/drone/.cocoapods_cache.lock'
  ],
  depends_on: [
    'Clone Submodules'
  ]
};

// Override the cached CocoaPods directory (to speed up the next build)
local update_cocoapods_cache(depends_on) = {
  name: 'Update CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/drone/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/drone/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/drone/.cocoapods_cache.lock',
    |||
      if [[ -d ./Pods ]]; then
        rm -rf /Users/drone/.cocoapods_cache
        cp -r ./Pods /Users/drone/.cocoapods_cache
      fi
    |||,
    'rm -f /Users/drone/.cocoapods_cache.lock'
  ],
  depends_on: depends_on,
};

[
  // Unit tests (PRs only)
//  {
//    kind: 'pipeline',
//    type: 'exec',
//    name: 'Unit Tests',
//    platform: { os: 'darwin', arch: 'amd64' },
//    trigger: { event: { exclude: [ 'push' ] } },
//    steps: [
//      version_info,
//      clone_submodules,
//      load_cocoapods_cache,
//      install_cocoapods,
//      {
//        name: 'Reset Simulators',
//        commands: [
//          'xcrun simctl shutdown all',
//          'xcrun simctl erase all'
//        ],
//        depends_on: [
//          'Install CocoaPods'
//        ]
//      },
//      {
//        name: 'Build and Run Tests',
//        commands: [
//          'mkdir build',
//          'NSUnbufferedIO=YES set -o pipefail && xcodebuild test -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -resultBundlePath ./build/artifacts/testResults.xcresult -destination "platform=iOS Simulator,name=iPhone 14" -test-timeouts-enabled YES -maximum-test-execution-time-allowance 10 -collect-test-diagnostics never 2>&1 | xcbeautify --is-ci',
//        ],
//        depends_on: [
//          'Install CocoaPods'
//        ],
//      },
//      {
//        name: 'Unit Test Summary',
//        commands: [
//          'xcresultparser --output-format cli --failed-tests-only ./build/artifacts/testResults.xcresult',
//        ],
//        depends_on: ['Build and Run Tests'],
//        when: {
//          status: ['failure', 'success']
//        }
//      },
//      {
//        name: 'Shutdown Simulators',
//        commands: [ 'xcrun simctl shutdown all' ],
//        depends_on: [
//          'Build and Run Tests',
//        ],
//        when: {
//          status: ['failure', 'success']
//        }
//      },
//      update_cocoapods_cache(['Build For Testing'])
//    ],
//  },
//  // Validate build artifact was created by the direct branch push (PRs only)
//  {
//    kind: 'pipeline',
//    type: 'exec',
//    name: 'Check Build Artifact Existence',
//    platform: { os: 'darwin', arch: 'amd64' },
//    trigger: { event: { exclude: [ 'push' ] } },
//    steps: [
//      {
//        name: 'Poll for build artifact existence',
//        commands: [
//          './Scripts/drone-upload-exists.sh'
//        ]
//      }
//    ]
//  },
  // Simulator build (non-PRs only)
//  {
//    kind: 'pipeline',
//    type: 'exec',
//    name: 'Simulator Build',
//    platform: { os: 'darwin', arch: 'amd64' },
//    trigger: { event: { exclude: [ 'pull_request' ] } },
//    steps: [
//      version_info,
//      clone_submodules,
//      load_cocoapods_cache,
//      install_cocoapods,
//      {
//        name: 'Build',
//        commands: [
//          'mkdir build',
//          'xcodebuild archive -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -parallelizeTargets -configuration "App Store Release" -sdk iphonesimulator -archivePath ./build/Session_sim.xcarchive -destination "generic/platform=iOS mulator" | xcbeautify --is-ci'
//        ],
//        depends_on: [
//          'Install CocoaPods'
//        ],
//      },
//      update_cocoapods_cache(['Build']),
//      {
//        name: 'Upload artifacts',
//        environment: { SSH_KEY: { from_secret: 'SSH_KEY' } },
//        commands: [
//          './Scripts/drone-static-upload.sh'
//        ],
//        depends_on: [
//          'Build'
//        ]
//      },
//    ],
//  },
  // Unit tests and Codecov upload (non-PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Unit Tests and Code Coverage',
    platform: { os: 'darwin', arch: 'amd64' },
    trigger: { event: { exclude: [ 'pull_request' ] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      {
        name: 'Pre-Boot Test Simulator',
        commands: [
          'DEVICE_NAME="Test-iPhone14-${DRONE_COMMIT:0:9}-${DRONE_BUILD_EVENT}"',
          'xcrun simctl create ${DEVICE_NAME} com.apple.CoreSimulator.SimDeviceType.iPhone-14',
          'SIM_UUID=$(xcrun simctl list devices | grep -m 1 ${DEVICE_NAME} | grep -E -o -i "([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})")',
          'xcrun simctl boot ${SIM_UUID}',
          'echo "[32mPre-booting simulator complete: $(xcrun simctl list | sed "s/^[[:space:]]*//" | grep -o ".*${SIM_UUID}.*")[0m"',
        ]
      },
      {
        name: 'Build and Run Tests',
        commands: [
          'mkdir build',
          'NSUnbufferedIO=YES set -o pipefail && xcodebuild test -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -resultBundlePath ./build/artifacts/testResults.xcresult -destination "platform=iOS Simulator,id=${SIM_UUID}" -test-timeouts-enabled YES -maximum-test-execution-time-allowance 10 -collect-test-diagnostics never 2>&1 | xcbeautify --is-ci',
        ],
        depends_on: [
          'Pre-Boot Test Simulator',
          'Install CocoaPods'
        ],
      },
      {
        name: 'Unit Test Summary',
        commands: [
          'xcresultparser --output-format cli --failed-tests-only ./build/artifacts/testResults.xcresult',
        ],
        depends_on: ['Build and Run Tests'],
        when: {
          status: ['failure', 'success']
        }
      },
      {
        name: 'Delete Test Simulator',
        commands: [ 'xcrun simctl delete ${SIM_UUID}' ],
        depends_on: [
          'Build and Run Tests',
        ],
        when: {
          status: ['failure', 'success']
        }
      },
      update_cocoapods_cache(['Build and Run Tests']),
      {
        name: 'Install Codecov CLI',
        commands: [
          'pip3 install codecov-cli',
          '~/Library/Python/3.9/bin/codecovcli --version'
        ],
      },
      {
        name: 'Convert xcresult to xml',
        commands: [
          'xcresultparser --output-format cobertura ./build/artifacts/testResults.xcresult > ./build/artifacts/coverage.xml',
        ],
        depends_on: ['Build and Run Tests']
      },
      {
        name: 'Upload coverage to Codecov',
        environment: { CODECOV_TOKEN: { from_secret: 'CODECOV_TOKEN' } },
        commands: [
          '~/Library/Python/3.9/bin/codecovcli --verbose upload-process --fail-on-error -t ${CODECOV_TOKEN} -n "service-${DRONE_BUILD_NUMBER}" -F service -f ./build/artifacts/coverage.xml',
        ],
        depends_on: [
          'Convert xcresult to xml',
          'Install Codecov CLI'
        ]
      },
    ],
  },
]