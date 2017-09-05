#!/bin/bash

# Set constants

docker_base_name="kovri_testnet"

pid=$(id -u)
gid="docker" # Assumes user is in docker group

# TODO(unassigned): better sequencing impl
#Note: sequence limit [2:254]
seq_start=10  # Not 0 because of port assignments, not 1 because we can't use IP ending in .1 (assigned to gateway)
seq_end=$((${seq_start} + 19))  # TODO(unassigned): arbitrary end amount
sequence="seq -f "%03g" ${seq_start} ${seq_end}"

#Note: this can avoid to rebuild the docker image
#custom_build_dir="-v /home/user/kovri/build/kovri:/usr/bin/kovri -v /home/user/kovri/build/kovri-util:/usr/bin/kovri-util"

reseed_file="reseed.zip"

PrintUsage()
{
  echo "Usage: $ $0 {create|start|stop|destroy}" >&2
}

if [ "$#" -ne 1 ]
then
  PrintUsage
  exit 1
fi

Prepare()
{
  # Cleanup for new testnet
  if [[ $KOVRI_WORKSPACE || $KOVRI_NETWORK ]]; then
    read_input "Kovri testnet environment detected. Attempt to destroy previous testnet?" NULL cleanup_testnet
  fi
  set_repo
  set_image
  set_workspace
  set_args
  set_network
}

cleanup_testnet()
{
  Destroy
  if [[ $? -ne 0 ]]; then
    echo "Previous testnet not found, continuing creation"
  fi
}

set_repo()
{
  # Set Kovri repo location
  if [[ -z $KOVRI_REPO ]]; then
    KOVRI_REPO="/tmp/kovri"
    read_input "Change location of Kovri repo? [KOVRI_REPO=${KOVRI_REPO}]" KOVRI_REPO
  fi

  # Ensure repo
  if [[ ! -d $KOVRI_REPO ]]; then
    false
    catch "Kovri not found. See building instructions."
  fi
}

set_image()
{
  # Build Kovri image if applicable
  pushd $KOVRI_REPO
  catch "Could not access $KOVRI_REPO"

  # Set tag
  hash git 2>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "git is not installed, using default tag"
    local _docker_tag=":latest"
  else
    local _docker_tag=":$(git rev-parse --short HEAD)"
  fi

  # If image name not set, provide name options + build options
  local _default_image="geti2p/kovri${_docker_tag}"
  if [[ -z $KOVRI_IMAGE ]]; then
    KOVRI_IMAGE=${_default_image}
    read_input "Change image name?: [KOVRI_IMAGE=${KOVRI_IMAGE}]" KOVRI_IMAGE
  fi

  # If input was null
  if [[ -z $KOVRI_IMAGE ]]; then
    KOVRI_IMAGE=${_default_image}
  fi

  read_input "Build Kovri Docker image? [$KOVRI_IMAGE]" NULL "docker build -t $KOVRI_IMAGE $KOVRI_REPO"
  popd
}

set_workspace()
{
  # Set testnet workspace
  if [[ -z $KOVRI_WORKSPACE ]]; then
    KOVRI_WORKSPACE="${KOVRI_REPO}/build/testnet"
    read_input "Change workspace for testnet output? [KOVRI_WORKSPACE=${KOVRI_WORKSPACE}]" KOVRI_WORKSPACE
  fi

  # Ensure workspace
  if [[ ! -d $KOVRI_WORKSPACE ]]; then
    echo "$KOVRI_WORKSPACE does not exist, creating"
    mkdir -p $KOVRI_WORKSPACE 2>/dev/null
    catch "Could not create workspace"
  fi
}

set_args()
{
  # TODO(unassigned): *all* arguments (including sequence count, etc.)
  # Set utility binary arguments
  if [[ -z $KOVRI_UTIL_ARGS ]]; then
    KOVRI_UTIL_ARGS="--floodfill 1 --bandwidth P"
    read_input "Change utility binary arguments? [KOVRI_UTIL_ARGS=\"${KOVRI_UTIL_ARGS}\"]" KOVRI_UTIL_ARGS
  fi

  # Set daemon binary arguments
  if [[ -z $KOVRI_BIN_ARGS ]]; then
    KOVRI_BIN_ARGS="--log-level 5 --floodfill 1 --enable-ntcp 0 --disable-su3-verification 1"
    read_input "Change kovri binary arguments? [KOVRI_BIN_ARGS=\"${KOVRI_BIN_ARGS}\"]" KOVRI_BIN_ARGS
  fi
}

set_network()
{
  # Create network
  # TODO(anonimal): we splitup octet segments as a hack for later setting RI addresses
  if [[ -z $KOVRI_NETWORK ]]; then
    KOVRI_NETWORK="kovri-testnet"
  fi
  if [[ -z $network_octets ]]; then
    network_octets="172.18.0"
  fi
  network_subnet="${network_octets}.0/16"
}

create_network()
{
  echo "Creating $KOVRI_NETWORK"
  docker network create --subnet=${network_subnet} $KOVRI_NETWORK

  if [[ $? -ne 0 ]]; then
    read -r -p "Create a new network? [Y/n] " REPLY
    case $REPLY in
      [nN])
        echo "Could not finish testnet creation"
        exit 1
        ;;
      *)
        read -r -p "Set network name: " REPLY
        KOVRI_NETWORK=${REPLY}
        read -r -p "Set first 3 octets: " REPLY
        network_octets=${REPLY}
        set_network
        ;;
    esac

    # Fool me once, shame on you. Fool me twice, ...
    docker network create --subnet=${network_subnet} $KOVRI_NETWORK
    catch "Docker could not create network"
  fi

  echo "Created network: $KOVRI_NETWORK"
}

Create()
{
  # Create network
  create_network

  # Create workspace
  pushd $KOVRI_WORKSPACE

  for _seq in $($sequence); do
    # Setup router dir
    local _dir="router_${_seq}"

    # Create data dir
    local _data_dir="${_dir}/.kovri"
    mkdir -p $_data_dir
    catch "Could not create $_data_dir"

    # Set permissions
    chown -R ${pid}:${gid} ${KOVRI_WORKSPACE}/${_dir}
    catch "Could not set ownership ${pid}:${gid}"

    # Create RI's
    local _host="${network_octets}.$((10#${_seq}))"
    local _port="${seq_start}${_seq}"
    local _mount="/home/kovri"
    local _volume="${KOVRI_WORKSPACE}/${_dir}:${_mount}"
    docker run -w $_mount -it --rm \
      -v $_volume \
      $custom_build_dir \
      $KOVRI_IMAGE /usr/bin/kovri-util routerinfo --create \
        --host $_host \
        --port $_port \
        $KOVRI_UTIL_ARGS
    catch "Docker could not run"
    echo "Created RI | host: $_host | port: $_port | args: $KOVRI_UTIL_ARGS | volume: $_volume"

    # Create container
    local _container_name="${docker_base_name}_${_seq}"
    docker create -w /home/kovri \
      --name $_container_name \
      --hostname $_container_name \
      --net $KOVRI_NETWORK \
      --ip $_host \
      -p ${_port}:${_port} \
      -v ${KOVRI_WORKSPACE}:/home/kovri/testnet \
      $custom_build_dir \
      $KOVRI_IMAGE /usr/bin/kovri \
      --data-dir /home/kovri/testnet/kovri_${_seq} \
      --reseed-from /home/kovri/testnet/${reseed_file} \
      --host $_host \
      --port $_port \
      $KOVRI_BIN_ARGS
    catch "Docker could not create container"
  done

  ## ZIP RIs to create unsigned reseed file
  # TODO(unassigned): ensure the zip binary is available
  local _tmp="tmp"
  mkdir $_tmp \
    && cp $(ls router_*/routerInfo* | grep -v key) $_tmp \
    && cd $_tmp \
    && zip $reseed_file * \
    && mv $reseed_file $KOVRI_WORKSPACE \
    && cd .. \
    && rm -rf ${KOVRI_WORKSPACE}/${_tmp}
  catch "Could not ZIP RI's"

  for _seq in $($sequence); do
    # Create data-dir + copy only what's needed from pkg
    mkdir -p kovri_${_seq}/core && cp -r ${KOVRI_REPO}/pkg/{client,config,*.sh} kovri_${_seq}
    catch "Could not copy package resources / create data-dir"

    ## Default with 1 server tunnel
    echo "\
[MyServer]
type = server
address = 127.0.0.1
port = 2222
in_port = 2222
keys = server-keys.dat
;white_list =
;black_list =
" > kovri_${_seq}/config/tunnels.conf
    catch "Could not create server tunnel"

    ## Put RI + key in correct location
    cp $(ls router_${_seq}/routerInfo*.dat) kovri_${_seq}/core/router.info
    cp $(ls router_${_seq}/routerInfo*.key) kovri_${_seq}/core/router.keys
    catch "Could not copy RI and key"

    chown -R ${pid}:${gid} kovri_${_seq}
    catch "Could not set ownership ${pid}:${gid}"
  done
  popd
}

Start()
{
  for _seq in $($sequence); do
    local _container_name="${docker_base_name}_${_seq}"
    echo -n "Starting... " && docker start $_container_name
    catch "Could not start docker: $_seq"
  done
}

Stop()
{
  for _seq in $($sequence); do
    local _container_name="${docker_base_name}_${_seq}"
    echo -n "Stopping... " && docker stop $_container_name
    catch "Could not stop docker: $_seq"
  done
}

Destroy()
{
  echo "Destroying... [Workspace: $KOVRI_WORKSPACE | Network: $KOVRI_NETWORK]"

  # TODO(unassigned): error handling?
  if [[ -z $KOVRI_WORKSPACE ]]; then
    read -r -p "Enter workspace to remove: " REPLY
    KOVRI_WORKSPACE=${REPLY}
  fi

  Stop

  for _seq in $($sequence); do
    local _container_name="${docker_base_name}_${_seq}"
    echo -n "Removing... " && docker rm -v $_container_name
    rm -rf ${KOVRI_WORKSPACE}/router_${_seq}
    rm -rf ${KOVRI_WORKSPACE}/kovri_${_seq}
  done

  rm ${KOVRI_WORKSPACE}/${reseed_file}

  if [[ -z $KOVRI_NETWORK ]]; then
    read -r -p "Enter network name to remove: " REPLY
    KOVRI_NETWORK=${REPLY}
  fi

  docker network rm $KOVRI_NETWORK && echo "Removed network: $KOVRI_NETWORK"
}

# Error handler
catch()
{
  if [[ $? -ne 0 ]]; then
    echo "$1" >&2
    exit 1
  fi
}

# Read handler
# $1 - message
# $2 - varname to set
# $3 - function or string to execute
read_input()
{
  read -r -p "$1 [Y/n] " REPLY
  case $REPLY in
    [nN])
      ;;
    *)
      if [[ $2 != "NULL" ]]; then  # hack to ensure 2nd arg is unused
        read -r -p "Set new: " REPLY
        eval ${2}=\"${REPLY}\"
      fi
      $3
      ;;
  esac
}

case "$1" in
  create)
    Prepare && Create && echo "Kovri testnet created"
    ;;
  start)
    Start && echo "Kovri testnet started"
    ;;
  stop)
    Stop && echo "Kovri testnet stopped"
    ;;
  destroy)
    Destroy && echo "Kovri testnet destroyed"
    ;;
  *)
    PrintUsage
    exit 1
esac
