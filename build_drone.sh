#!/bin/bash
OPTIONS_HELP='
Options to build batch-shipyard in ConnectedDrones project:
  -br|--branch                 (Required) source branch to build, used as image tag
  -b|--build    <true|false>   (Optional) build batch-shipyard image
  -p|--push     <true|false>   (Optional) push the new docker image after built
  -h|--help                     Print this help menu
'

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -br|--branch)
    branch="$2"
    shift # past argument
    shift # past value
    ;;
    -b|--build)
    build="$2"
    shift # past argument
    shift # past value
    ;;
    -p|--push)
    push="$2"
    shift # past argument
    shift # past value
    ;;
    -h|--help)
    echo "$OPTIONS_HELP"
    exit 1
    ;;
    *)    # unknown option
    echo "ERROR: Unknown option"
    echo "$OPTIONS_HELP"
    exit 1
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [ -z ${branch} ] ; then
  echo "ERROR: Should have a source branch. Use -br|--branch"
  exit 1
fi

if [ -z ${build} ] ; then
  build=false
fi

if [ -z ${push} ] ; then
  push=false
fi


repo=esmartconnecteddrones-on.azurecr.io
namespace=esmartconnecteddrones
project=batch-shipyard
image=${repo}/${namespace}/${project}:${branch}

if [ ${build} = true ] ; then
  echo 'building...'
  docker build --build-arg GIT_BRANCH=${branch} -t ${image} -f docker/drone/Dockerfile .
fi

if [ ${push} = true ] ; then
  echo 'pushing to hub ...'
  docker push ${image}
fi

