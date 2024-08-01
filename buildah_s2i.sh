#!/usr/bin/env bash
#
# This script emulates an S2I (https://github.com/openshift/source-to-image)
# build process performed only via buildah.
#
# It is able to perform incremental builds.
#
# Version 0.0.8
#
# Copyright 2023, 2024 Giuseppe Magnotta giuseppe.magnotta@gmail.com
#
# Expected environment variables:
# BUILDER_IMAGE -> The builder image to use
# OUTPUT_IMAGE -> The image that will be build
# INCREMENTAL -> If incremental build should be used
# CONTEXT_DIR -> If there is a specific directory containing source
set -eu -o pipefail

BUILDER_IMAGE=${BUILDER_IMAGE:-""}
OUTPUT_IMAGE=${OUTPUT_IMAGE:-""}
INCREMENTAL=${INCREMENTAL:-false}
CONTEXT_DIR=${CONTEXT_DIR:-"."}
TLSVERIFY=${TLSVERITY:-"true"}
BUILDAH_PARAMS=${BUILDAH_PARAMS:-""}

echo "Start build process with builder image $BUILDER_IMAGE"

buildah $BUILDAH_PARAMS pull --tls-verify=$TLSVERIFY $BUILDER_IMAGE

SCRIPTS_URL=$(buildah $BUILDAH_PARAMS inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.scripts-url"}}' $BUILDER_IMAGE)
DESTINATION_URL=$(buildah $BUILDAH_PARAMS inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.destination"}}' $BUILDER_IMAGE)
ASSEMBLE_USER=$(buildah $BUILDAH_PARAMS inspect -f '{{index .OCIv1.Config.Labels "io.openshift.s2i.assemble-user"}}' $BUILDER_IMAGE)

if [ -z "$SCRIPTS_URL" ]
then
  echo "Image not compatible with S2I. Terminating"
  exit -1
else
  if [ -z "$DESTINATION_URL" ]
  then
    echo "WARNING: Image is not defining DESTINATION URL. Assuming /tmp"
    DESTINATION_URL=/tmp
  fi
  SCRIPTS_URL=$(echo -n "$SCRIPTS_URL" | sed 's/image:\/\///g' | tr -d '"')
  DESTINATION_URL=$(echo -n "$DESTINATION_URL" | tr -d '"')

fi

if [ -z "$ASSEMBLE_USER" ]
then
  ASSEMBLE_USER=$(buildah $BUILDAH_PARAMS inspect -f '{{.OCIv1.Config.User}}' $BUILDER_IMAGE)

  if [ -z "$ASSEMBLE_USER" ]
  then
    echo "WARNING: Unable to determine the USER to build container. Assuming root!"
    ASSEMBLE_USER="root"
  fi

fi

ASSEMBLE_USER=$(echo -n "$ASSEMBLE_USER" | tr -d '"')

builder=$(buildah $BUILDAH_PARAMS from --ulimit nofile=90000:90000 --tls-verify=$TLSVERIFY $BUILDER_IMAGE)

echo "Copy from ./$CONTEXT_DIR to $DESTINATION_URL/src"
buildah $BUILDAH_PARAMS add --chown $ASSEMBLE_USER:0 $builder ./$CONTEXT_DIR $DESTINATION_URL/src

# If incremental build is enabled and there is an artifacts.tar file, then
# copy it to the builder image
if [ "$INCREMENTAL" = "true" ]; then

    if [ -f "./artifacts.tar" ]; then
        echo "Restoring artifacts for incremental build"
        buildah $BUILDAH_PARAMS add --chown $ASSEMBLE_USER:0 $builder ./artifacts.tar $DESTINATION_URL/artifacts
    fi

fi

# Construct enviroment variables to be used during the assemble script
ENV=""
if [ -f "$CONTEXT_DIR/.s2i/environment" ]; then
    echo "Using $CONTEXT_DIR/.s2i/environment"

    while IFS="" read -r line
    do
      [[ "$line" =~ ^#.*$ ]] && continue

        KEY=$(echo $line|cut -d "=" -f 1)
        LEN=${#KEY}
        VALUE=${line:$LEN+1}
        ENV+="-e $KEY='$VALUE' "
    done < $CONTEXT_DIR/.s2i/environment

    #if [ ! -z "$ENV" ]
    #then
    #  echo "ENV is $ENV"
    #fi
fi

# Set run script as CMD
echo "Setting CMD $SCRIPTS_URL/run"
buildah $BUILDAH_PARAMS config --cmd $SCRIPTS_URL/run $builder

# Run assemble script. If there is an assemble script in .s2i/bin directory
# it takes precedence
ASSEMBLE_SCRIPT="$SCRIPTS_URL/assemble"

if [ -x "$CONTEXT_DIR/.s2i/bin/assemble" ]; then

    echo "Replacing assemble file from .s2i/bin"
    ASSEMBLE_SCRIPT="$DESTINATION_URL/src/.s2i/bin/assemble"
fi

echo "Running assemble $ASSEMBLE_SCRIPT"
eval buildah $BUILDAH_PARAMS run $ENV $builder -- $ASSEMBLE_SCRIPT

# If incremental build is enabled, and image provide save-artifacts script,
# then call it and backup artifacts
if [ "$INCREMENTAL" = "true" ]; then

    echo "Saving artifacts"
    if [ -f "./artifacts.tar" ]; then
        rm ./artifacts.tar
    fi

    buildah $BUILDAH_PARAMS run $builder -- /bin/bash -c "if [ -x \"$SCRIPTS_URL/save-artifacts\" ]; then $SCRIPTS_URL/save-artifacts ; fi" > ./artifacts.tar

fi


echo "Committing image $OUTPUT_IMAGE"
buildah $BUILDAH_PARAMS commit --iidfile /tmp/ImageIDfile $builder $OUTPUT_IMAGE


echo "Deleting temporary images"
buildah $BUILDAH_PARAMS rm $builder
