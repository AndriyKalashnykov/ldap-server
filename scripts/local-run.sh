#!/bin/bash

# set -x

LAUNCH_DIR=$(pwd); SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd $SCRIPT_DIR; cd ..; SCRIPT_PARENT_DIR=$(pwd);

. $SCRIPT_DIR/set-env.sh

cd $SCRIPT_DIR/..

mvn clean install
java -jar ./target/ldap-server.jar ./target/classes/

cd $LAUNCH_DIR
