#!/bin/bash
DECAPOD_BASE_DIR=decapod-base-yaml
DECAPOD_BASE_URL=https://github.com/openinfradev/${DECAPOD_BASE_DIR}.git
TKS_CUSTOM_BASE_DIR=tks-custom-base-yaml
TKS_CUSTOM_BASE_URL=https://$USERNAME:$API_TOKEN_GITHUB@github.com/openinfradev/${TKS_CUSTOM_BASE_DIR}.git
BRANCH="release-v2"

rm -rf $DECAPOD_BASE_DIR $TKS_CUSTOM_BASE_DIR

site_list=$(ls -d */ | sed 's/\///g' | egrep -v "docs|^template|^deprecated|output" )

# output directory which will contain finally rendered k8s manifests
outputdir="output"
if [ $# -eq 1 ]; then
  BRANCH=$1
elif [ $# -eq 2 ]; then
  BRANCH=$1
  outputdir=$2
elif [ $# -eq 3 ]; then
  BRANCH=$1
  outputdir=$2
  site_list=$3
fi

echo "[render-cd] dacapod branch=$BRANCH, output directory=$outputdir ,target site(s)=${site_list}\n\n"

echo "Fetching decapod-base with $BRANCH branch/tag........"
git clone -b $BRANCH $DECAPOD_BASE_URL
if [ $? -ne 0 ]; then
  echo "Error while cloning from $DECAPOD_BASE_URL"
  exit $?
fi

echo "Fetching tks-custom-base with $BRANCH branch/tag........"
git clone -b $BRANCH $TKS_CUSTOM_BASE_URL
if [ $? -ne 0 ]; then
  echo "Error while cloning from $TKS_CUSTOM_BASE_URL"
  exit $?
fi

mkdir $outputdir

for site in ${site_list}
do
  echo "[render-cd] Starting build manifests for '$site' site"

  for app in `ls $site/`
  do
    # helm-release file name rendered on 1st phase
    hr_file="$DECAPOD_BASE_DIR/$app/$site/$app-manifest.yaml"

    if [ -d ./$DECAPOD_BASE_DIR/$app ]; then
      # Case where app dir exists in both repos: not supported yet.
      if [ -d ./$TKS_CUSTOM_BASE_DIR/$app ]; then
        echo "$app directory exists in both decapod-base and custom-base. This case is not supported yet."
        exit 1
      # Common case (app dir only exists in decapod-base)
      else
        echo "No cutom-base for $app app. Just doing normal merge.."
      fi
    # If app dir only exists in custom-base, then copy the dir into decapod-base.
    # (E.g., tks-cluster)
    elif [ -d ./$TKS_CUSTOM_BASE_DIR/$app ]; then
      # check if
      # 1. the app dir has resource.yaml and kustomization.yaml points to current dir
      # 2. site directory's kustomization.yaml points to ../base dir
      # otherwise it's an error!
      if [ -f ./$TKS_CUSTOM_BASE_DIR/$app/base/resources.yaml ] && grep resources.yaml ./$TKS_CUSTOM_BASE_DIR/$app/base/kustomization.yaml; then
        echo "No decapod-base for $app app. Using custom-base as base configuration.."
        cp -r $TKS_CUSTOM_BASE_DIR/$app $DECAPOD_BASE_DIR/
      else
        echo "Error: no resources.yaml file or wrong kustomization.yaml!"
        exit 1
      fi
    else
      echo "There's no base configuration for $app app at all. Exiting..."
      exit 1
    fi

    mkdir $DECAPOD_BASE_DIR/$app/$site

    # Copy site-values into decapod-base
    cp -r $site/$app/*.yaml $DECAPOD_BASE_DIR/$app/$site/

    echo "Rendering $app-manifest.yaml for $site site"
    docker run --rm -i -v $(pwd)/$DECAPOD_BASE_DIR/$app:/$app --name kustomize-build sktdev/decapod-kustomize:latest kustomize build --enable_alpha_plugins /$app/$site -o /$app/$site/$app-manifest.yaml
    build_result=$?

    if [ $build_result != 0 ]; then
      exit $build_result
    fi

    if [ -f "$hr_file" ]; then
      echo "[render-cd] [$site, $app] Successfully Generate Helm-Release Files!"
    else
      echo "[render-cd] [$site, $app] Failed to render $app-manifest.yaml"
      exit 1
    fi

    docker run --rm -i --net=host -v $(pwd)/$DECAPOD_BASE_DIR:/decapod-base-yaml -v $(pwd)/$outputdir:/out --name generate sktcloud/helmrelease2yaml:v1.5.0 -m $hr_file -t -o /out/$site/$app
    rm $hr_file

  done

  # Post processes for the customized action
  #   Action1. change the namespace for aws-cluster-resouces from argo to cluster-name
  echo "almost finished :  change the namespace for aws-cluster-resouces from argo to cluster-name"
  sudo sed -i "s/ namespace: argo/ namespace: $site/g" $(pwd)/output/$site/tks-cluster-aws/cluster-api-aws/*
  sudo sed -i "s/ - argo/ - $site/g" $(pwd)/output/$site/tks-cluster-aws/cluster-api-aws/*
  # It's possible besides of two above but very tricky!!
  # sudo sed -i "s/ argo$/ $site/g" $(pwd)/output/$site/tks-cluster-aws/cluster-api-aws/*
  echo "---
apiVersion: v1
kind: Namespace
metadata:
  name: $site
  labels:
    name: $site
    # It bring the secret 'dacapod-argocd-config' using kubed
    decapod-argocd-config: enabled
" > Namespace_aws_rc.yaml
  sudo mv Namespace_aws_rc.yaml $(pwd)/output/$site/tks-cluster-aws/cluster-api-aws/
  # End of Post process

done

rm -rf $DECAPOD_BASE_DIR $TKS_CUSTOM_BASE_DIR
