#!/bin/bash

if [[ "$DOCKER_DEFAULT_PLATFORM" == linux/amd64 ]]; then
  echo "Looks like you've set DOCKER_DEFAULT_PLATFORM to force amd64:"
  echo " - We want to run a native aarch64 container for you, don't worry we will swap the jdk"
  echo " - You could try unset DOCKER_DEFAULT_PLATFORM, then run this again"
  echo " - More details https://github.com/karl-denby/mongo-infra-docker/issues/72"
  exit 1
fi

main_options=("Download from internet" "Already downloaded" "Build locally")
echo "Choose how you want to set up Ops Manager:"
select opt in "${main_options[@]}"; do
  case $opt in
    "Download from internet")
      echo "Select specific version to download:"
      version_options=("8-0-1" "7-0-10" "6-0-25")
      select veropt in "${version_options[@]}"; do
        case $veropt in
          8-0-1)
            export version='8.0.1'
            export version_for_url='8.0'
            break
            ;;
          7-0-10)
            export version='7.0.10'
            export version_for_url='7.0'
            break
            ;;
          6-0-25)
            export version='6.0.25'
            export version_for_url='6.0'
            break
            ;;
          *)
            echo "Invalid version"
            ;;
        esac
      done
      break
      ;;
    "Already downloaded")
      if [[ -e downloads/8.local.ver ]]; then
        export version='8.local'
        export version_for_url='8.0'
      elif [[ -e downloads/8.ver ]]; then
        export version='8.0.1'
        export version_for_url='8.0'
      elif [[ -e downloads/7.local.ver ]]; then
        export version='7.local'
        export version_for_url='7.0'
      elif [[ -e downloads/7.ver ]]; then
        export version='7.0.10'
        export version_for_url='7.0'
      elif [[ -e downloads/6.local.ver ]]; then
        export version='6.local'
        export version_for_url='6.0'
      elif [[ -e downloads/6.ver ]]; then
        export version='6.0.25'
        export version_for_url='6.0'
      else
        echo "No downloaded version markers found. Aborting."
        exit 1
      fi
      export skip_download='true'
      break
      ;;
    "Build locally")
      echo "Please select the OM major version you're building:"
      select local_ver in "8.x" "7.x" "6.x"; do
        case $local_ver in
          8.x)
            export version="8.local"
            export version_for_url="8.0"
            break
            ;;
          7.x)
            export version="7.local"
            export version_for_url="7.0"
            break
            ;;
          6.x)
            export version="6.local"
            export version_for_url="6.0"
            break
            ;;
          *)
            echo "Invalid selection"
            ;;
        esac
      done
      break
      ;;
    *)
      echo "Invalid option"
      ;;
  esac
done

platform_options=("M1-Mac" "Intel-Mac" "Linux" "Linux-ARM" "Quit")
[[ "$version" == *.local ]] && platform_options=("M1-Mac")
echo "Please choose a platform:"
select opt in "${platform_options[@]}"; do
  case $opt in
    M1-Mac)
      echo "Configuring for an M1/M2/Mxxx Mac"
      sed -i '' 's/x86_64/aarch64/g' docker-compose.yml # weird mac sed
      export platform="aarch64"
      export distro="amzn2"
      break
      ;;
    Intel-Mac)
      echo "Configuring for an Intel Mac"
      sed -i '' 's/aarch64/x86_64/g' docker-compose.yml # weird mac sed
      export platform="x86_64"
      export distro="rhel8"
      break
      ;;
    Linux)
      echo "Configuring for Linux/Windows"
      sed -i 's/aarch64/x86_64/g' docker-compose.yml  # normal sed
      export platform="x86_64"
      export distro="rhel8"
      break
      ;;
    Linux-ARM)
      echo "Configuring for Generic-ARM"
      sed -i 's/x86_64/aarch64/g' docker-compose.yml  # linux dev server
      export platform="aarch64"
      export distro="amzn2"
      break
      ;;
    Quit)
      echo "Bye."
      exit 0
      ;;
    *)
      echo "Invalid option"
      ;;
  esac
done

if [[ "$version_for_url" == "8.0" ]]; then
  urls=("https://repo.mongodb.com/yum/redhat/8/mongodb-enterprise/${version_for_url}/${platform}/RPMS/mongodb-enterprise-server-8.0.1-1.el8.${platform}.rpm" \
        "https://downloads.mongodb.com/on-prem-mms/rpm/mongodb-mms-8.0.1.500.20241030T1559Z.x86_64.rpm" \
        "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_aarch64_linux_hotspot_21.0.5_11.tar.gz" \
        "http://localhost:8080/download/agent/automation/mongodb-mms-automation-agent-manager-latest.${platform}.${distro}.rpm")
fi
if [[ "$version_for_url" == "7.0" ]]; then
  urls=("https://repo.mongodb.com/yum/redhat/8/mongodb-enterprise/${version_for_url}/${platform}/RPMS/mongodb-enterprise-server-7.0.0-1.el8.${platform}.rpm" \
        "https://downloads.mongodb.com/on-prem-mms/rpm/mongodb-mms-7.0.10.500.20240731T2149Z.x86_64.rpm" \
        "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.12_7.tar.gz" \
        "http://localhost:8080/download/agent/automation/mongodb-mms-automation-agent-manager-latest.${platform}.${distro}.rpm")
fi
if [[ "$version_for_url" == "6.0" ]]; then
  urls=("https://repo.mongodb.com/yum/redhat/8/mongodb-enterprise/${version_for_url}/${platform}/RPMS/mongodb-enterprise-server-6.0.0-1.el8.${platform}.rpm" \
        "https://downloads.mongodb.com/on-prem-mms/rpm/mongodb-mms-6.0.25.100.20240807T1538Z.x86_64.rpm" \
        "https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.24%2B8/OpenJDK11U-jdk_aarch64_linux_hotspot_11.0.24_8.tar.gz" \
        "http://localhost:8080/download/agent/automation/mongodb-mms-automation-agent-manager-latest.${platform}.${distro}.rpm")
fi

if [[ "$skip_download" != true ]]; then
  if [[ "$version" == *.local ]]; then
    CURRENT_VER_FILE="downloads/${version_for_url%%.*}.local.ver"
    JDK_PATH="downloads/jdk.${platform}.tar.gz"
    MONGO_PATH="downloads/mongodb-enterprise.${platform}.rpm"

    if [[ ! -f "$CURRENT_VER_FILE" || ! -f "$JDK_PATH" || ! -f "$MONGO_PATH" ]]; then
      echo "--- Missing or outdated JDK/MongoDB for local build ---"
      rm -f "$JDK_PATH" "$MONGO_PATH" downloads/*.ver

      echo "Downloading MongoDB Enterprise from ${urls[0]}"
      curl -o "$MONGO_PATH" -L "${urls[0]}"

      if [[ "$platform" == "aarch64" ]]; then
        echo "Downloading JDK from ${urls[2]}"
        curl -o "$JDK_PATH" -L "${urls[2]}"
      fi

      touch "$CURRENT_VER_FILE"
    else
      echo "--- Using cached MongoDB and JDK for local build ---"
    fi

    echo --- Preparing spec file for cross-compilation ---
    SPEC_FILE="$MMS_HOME/server/scripts/rpm/server/mms-bazel.spec.tpl"
    cp "$SPEC_FILE" "$SPEC_FILE.bak"

    trap 'echo --- Restoring original spec file ---; mv "$SPEC_FILE.bak" "$SPEC_FILE"' EXIT

    {
      echo "%define _target_cpu aarch64"
      echo "%define _target_os linux"
      cat "$SPEC_FILE"
    } > "$SPEC_FILE.tmp" && mv "$SPEC_FILE.tmp" "$SPEC_FILE"

    echo --- Building RPM locally using Bazel ---
    pushd "$MMS_HOME" || exit 1
    bazel build --build_env=distro //server:package_rpm || { echo "RPM build failed"; exit 1; }
    popd

    echo --- Copying generated RPM to ./downloads as mongodb-mms.x86_64.rpm ---
    rm -f ./downloads/mongodb-mms.x86_64.rpm
    cp -f "$MMS_HOME/bazel-bin/server/mongodb-mms.rpm" ./downloads/mongodb-mms.x86_64.rpm || {
      echo "Failed to copy RPM from bazel-bin to downloads"
      exit 1
    }

    trap - EXIT
    mv "$SPEC_FILE.bak" "$SPEC_FILE"

  else
    echo "Downloading MongoDB Enterprise from ${urls[0]}"
    rm -f downloads/mongodb-enterprise.${platform}.rpm
    curl -o downloads/mongodb-enterprise.${platform}.rpm -L "${urls[0]}"

    echo "Downloading Ops Manager from ${urls[1]}"
    rm -f downloads/mongodb-mms.x86_64.rpm
    curl -o downloads/mongodb-mms.x86_64.rpm -L "${urls[1]}"

    if [[ "$platform" == "aarch64" ]]; then
      echo "Downloading JDK from ${urls[2]}"
      rm -f downloads/jdk.${platform}.tar.gz
      curl -o downloads/jdk.${platform}.tar.gz -L "${urls[2]}"
    fi

    rm -f downloads/*.ver
    touch "downloads/${version_for_url%%.*}.ver"
  fi
fi

docker compose up -d ops --build

echo
echo --- Waiting 1 minute for Ops Manager to get going ---
echo
sleep 60
echo
echo --- Ops Manager setup ---
echo Please check http://localhost:8080 
echo If Ops Manager is running set central URL to http://ops.om.internal:8080
echo Please update 'mongodb-mms/automation-agent.config' with the correct values for:
echo
echo mmsGroupId=xxxxxxxxxxxxxxxxxx
echo mmsApiKey=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
echo
read -n 1 -p "Press Any Key to attempt Agent setup" mainmenuinput
echo

echo --- Downloading Agent ---
echo "downloading: ${urls[3]}"
curl -o downloads/mongodb-agent.${platform}.rpm -L "${urls[3]}"
docker compose build --no-cache node1
docker compose up -d node1
echo

echo --- Please check Ops Managers server tab for your running agents ---
echo Done