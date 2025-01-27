#!/bin/bash

# set -x

LAUNCH_DIR=$(pwd); SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd $SCRIPT_DIR; cd ..; SCRIPT_PARENT_DIR=$(pwd);

. $SCRIPT_DIR/set-env.sh

cd $SCRIPT_DIR/..

#docker rmi -f ${DOCKER_LOGIN}/$APACHEDS_IMAGE_NAME:$APACHEDS_VER
DOCKER_BUILDKIT=1 docker build -f Dockerfile -t ${DOCKER_LOGIN}/$APACHEDS_IMAGE_NAME:$APACHEDS_VER .

cd $LAUNCH_DIR
