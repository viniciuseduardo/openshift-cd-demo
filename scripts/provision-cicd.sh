#!/bin/bash

echo "###############################################################################"
echo "#  MAKE SURE YOU ARE LOGGED IN:                                               #"
echo "#  $ oc login http://console.your.openshift.com                               #"
echo "###############################################################################"

function usage() {
    echo
    echo "Usage:"
    echo " $0 [command] [options]"
    echo " $0 --help"
    echo
    echo "Example:"
    echo " $0 deploy"
    echo
    echo "COMMANDS:"
    echo "   deploy                   Configure CI/CD Stack in Openshift - Jenkins, Sonar, Nexus"
    echo "   delete                   Clean up and remove all CI/CD resources"
    echo "   idle                     Make all CI/CD services idle"
    echo "   unidle                   Make all CI/CD services unidle"
    echo 
    echo "OPTIONS:"
    echo "   --user [username]         The admin user for the CI/CD projects. mandatory if logged in as system:admin"
    echo "   --project-prefix [prefix] Prefix to be added to demo project names e.g. PREFIX-ci. If empty, user will be used as prefix"
    echo "   --ephemeral               Deploy demo without persistent storage. Default false"
    echo "   --oc-options              oc client options to pass to all oc commands e.g. --server https://my.openshift.com"
    echo
}

ARG_USERNAME=
ARG_PROJECT_PREFIX=
ARG_COMMAND=
ARG_EPHEMERAL=false
ARG_OC_OPS=

while :; do
    case $1 in
        deploy)
            ARG_COMMAND=deploy
            ;;
        delete)
            ARG_COMMAND=delete
            ;;
        idle)
            ARG_COMMAND=idle
            ;;
        unidle)
            ARG_COMMAND=unidle
            ;;
        --user)
            if [ -n "$2" ]; then
                ARG_USERNAME=$2
                shift
            else
                printf 'ERROR: "--user" requires a non-empty value.\n' >&2
                usage
                exit 255
            fi
            ;;
        --project-prefix)
            if [ -n "$2" ]; then
                ARG_PROJECT_SUFFIX=$2
                shift
            else
                printf 'ERROR: "--project-PREFIX" requires a non-empty value.\n' >&2
                usage
                exit 255
            fi
            ;;
        --oc-options)
            if [ -n "$2" ]; then
                ARG_OC_OPS=$2
                shift
            else
                printf 'ERROR: "--oc-options" requires a non-empty value.\n' >&2
                usage
                exit 255
            fi
            ;;
        --ephemeral)
            ARG_EPHEMERAL=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -?*)
            printf 'WARN: Unknown option (ignored): %s\n' "$1" >&2
            shift
            ;;
        *) # Default case: If no more options then break out of the loop.
            break
    esac

    shift
done


################################################################################
# CONFIGURATION                                                                #
################################################################################

LOGGEDIN_USER=$(oc $ARG_OC_OPS whoami)
OPENSHIFT_USER=${ARG_USERNAME:-$LOGGEDIN_USER}
PRJ_PREFIX=${ARG_PROJECT_PREFIX:-`echo $OPENSHIFT_USER | sed -e 's/[-@].*//g'`}
GITHUB_ACCOUNT=${GITHUB_ACCOUNT:-viniciuseduardo}
GITHUB_REF=${GITHUB_REF:-ocp-3.9}

function deploy() {
  oc $ARG_OC_OPS new-project $PRJ_PREFIX-cicd  --display-name="CI/CD"

  sleep 2

  if [ $LOGGEDIN_USER == 'system:admin' ] ; then
    oc $ARG_OC_OPS adm policy add-role-to-user admin $ARG_USERNAME -n $PRJ_PREFIX-cicd >/dev/null 2>&1
    
    oc $ARG_OC_OPS annotate --overwrite namespace $PRJ_PREFIX-cicd  app=openshift-cd-$PRJ_PREFIX >/dev/null 2>&1
  fi

  sleep 2

  oc new-app openshift/jenkins:custom -n $PRJ_PREFIX-cicd

  sleep 2

  local template=https://raw.githubusercontent.com/$GITHUB_ACCOUNT/openshift-cd-demo/$GITHUB_REF/cicd-template.yaml
  echo "Using template $template"
  oc $ARG_OC_OPS new-app -f $template --param=EPHEMERAL=$ARG_EPHEMERAL -n $PRJ_PREFIX-cicd 
}

function make_idle() {
  echo_header "Idling Services"
  oc $ARG_OC_OPS idle -n $PRJ_PREFIX-cicd --all
}

function make_unidle() {
  echo_header "Unidling Services"
  local _DIGIT_REGEX="^[[:digit:]]*$"

  for project in $PRJ_PREFIX-cicd
  do
    for dc in $(oc $ARG_OC_OPS get dc -n $project -o=custom-columns=:.metadata.name); do
      local replicas=$(oc $ARG_OC_OPS get dc $dc --template='{{ index .metadata.annotations "idling.alpha.openshift.io/previous-scale"}}' -n $project 2>/dev/null)
      if [[ $replicas =~ $_DIGIT_REGEX ]]; then
        oc $ARG_OC_OPS scale --replicas=$replicas dc $dc -n $project
      fi
    done
  done
}

function set_default_project() {
  if [ $LOGGEDIN_USER == 'system:admin' ] ; then
    oc $ARG_OC_OPS project default >/dev/null
  fi
}

function remove_storage_claim() {
  local _DC=$1
  local _VOLUME_NAME=$2
  local _CLAIM_NAME=$3
  local _PROJECT=$4
  oc $ARG_OC_OPS volumes dc/$_DC --name=$_VOLUME_NAME --add -t emptyDir --overwrite -n $_PROJECT
  oc $ARG_OC_OPS delete pvc $_CLAIM_NAME -n $_PROJECT >/dev/null 2>&1
}

function echo_header() {
  echo
  echo "########################################################################"
  echo $1
  echo "########################################################################"
}

################################################################################
# MAIN: DEPLOY DEMO                                                            #
################################################################################

if [ "$LOGGEDIN_USER" == 'system:admin' ] && [ -z "$ARG_USERNAME" ] ; then
  # for verify and delete, --project-prefix is enough
  if [ "$ARG_COMMAND" == "delete" ] || [ "$ARG_COMMAND" == "verify" ] && [ -z "$ARG_PROJECT_PREFIX" ]; then
    echo "--user or --project-prefix must be provided when running $ARG_COMMAND as 'system:admin'"
    exit 255
  # deploy command
  elif [ "$ARG_COMMAND" != "delete" ] && [ "$ARG_COMMAND" != "verify" ] ; then
    echo "--user must be provided when running $ARG_COMMAND as 'system:admin'"
    exit 255
  fi
fi

pushd ~ >/dev/null
START=`date +%s`

echo_header "OpenShift CI/CD Deploy ($(date))"

case "$ARG_COMMAND" in
    delete)
        echo "Delete CI/CD..."
        oc $ARG_OC_OPS delete project dev-$PRJ_PREFIX stage-$PRJ_PREFIX $PRJ_PREFIX-cicd
        echo
        echo "Delete completed successfully!"
        ;;
      
    idle)
        echo "Idling CI/CD..."
        make_idle
        echo
        echo "Idling completed successfully!"
        ;;

    unidle)
        echo "Unidling CI/CD..."
        make_unidle
        echo
        echo "Unidling completed successfully!"
        ;;

    deploy)
        echo "Deploying CI/CD..."
        deploy
        echo
        echo "Provisioning completed successfully!"
        ;;
        
    *)
        echo "Invalid command specified: '$ARG_COMMAND'"
        usage
        ;;
esac

set_default_project
popd >/dev/null

END=`date +%s`
echo "(Completed in $(( ($END - $START)/60 )) min $(( ($END - $START)%60 )) sec)"
echo 