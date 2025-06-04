#!/bin/sh

set -e
SCRIPT_NAME="test.sh"

display_usage() {
  echo $SCRIPT_NAME - executes tests for postproc
  echo "Usage: test [command: dags | rds | lambdas] [command --help | --help]"    
  echo Example: test rds --help
  echo     Displays rds specific help
  exit 0
}

display_command_usage() {
  echo $SCRIPT_NAME rds - executes rds tests for postproc
  if [ "$1" = "rds" ]; then
    echo "Usage: test rds [--cleanup]"
	  exit 0
  fi
}

# Ensure correct PROJECT_ROOT env var
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ -z "$PROJECT_ROOT" ]; then
	echo "PROJECT_ROOT environment variable is not set."
	echo "Please set the PROJECT_ROOT variable (ie: export PROJECT_ROOT=/home/user/postproc-lambdas)."
	exit 1
fi

# Parse command line args
while [[ $# -gt 0 ]]; do
  case $1 in
    dags)
      COMMAND=dags
      shift # past argument
      ;;
    rds)
      COMMAND=rds
      shift # past argument
      ;;
    lambdas)
      COMMAND=lambdas
      shift # past argument
      ;;
    -c|--cleanup)
      CLEANUP=true  
      shift # past argument
      ;;
    -h|--help)
      if [ -z "$COMMAND" ]; then
		    display_usage
      else
		    display_command_usage $COMMAND
      fi
      shift # past argument
      ;;
  esac
done


if [ -z "$COMMAND" ]; then
    display_usage
fi

if [ "$COMMAND" = "rds" ]; then
  clean_up() {
    echo "Cleaning up Docker containers and images..."
    PPI=$(docker images -q ghcr.io/coveware/postproc-lambdas-$BRANCH)
    if [ -n "$PPI" ]; then
      docker rmi --force $PPI
    fi
    RDSC=$(docker ps -aqf "name=rds")
    if [ -n "$RDSC" ]; then
      docker rm --force $RDSC
    fi
    RDSI=$(docker images -q postgres)
    if [ -n "$CLEANUP" ] && [ -n "$RDSI" ]; then
      docker rmi --force $RDSI
    fi
    exit 0
  }
  
  if [ -n "$CLEANUP" ]; then
    clean_up
  fi

  cd $PROJECT_ROOT
  docker build --platform linux/amd64 . -t ghcr.io/coveware/postproc-lambdas-$BRANCH:latest
  cd $PROJECT_ROOT/tests/rds
  BRANCH_NAME=$BRANCH docker compose run --rm test
  clean_up
fi

if [ "$COMMAND" = "dags" ]; then
    if [ -z "$VIRTUAL_ENV" ]; then
        echo "Virtual environment is not activated. Please activate it before running tests."
        exit 1
    fi

    pip install -r tests/dags/requirements.txt
    cd $PROJECT_ROOT/tests/dags

    docker_images_running() {
        if [ -n "$(docker ps -aqf "name=hadoop" -f "status=running")" ] &&
              [ -n "$(docker ps -aqf "name=moto" -f "status=running")" ] &&
              [ -n "$(docker ps -aqf "name=presto" -f "status=running")" ]; then
            echo true
        fi
    }

    IMAGES_RUNNING=$(docker_images_running)
    echo "images running: $IMAGES_RUNNING"

    if [ -z "$IMAGES_RUNNING" ]; then
        docker compose up -d &
    fi

    while !$(docker_images_running); do
        SPINUP_DELAY=true
        echo "Waiting for Hadoop, Moto, and Presto containers to start..."
        sleep 5
    done

    echo "****************** Hadoop, Moto, and Presto containers are up and running. ***********************"
    if [ -n "$SPINUP_DELAY" ]; then
        echo "Waiting for additional 60 seconds to ensure all services are fully operational..."
        sleep 60
    fi

    cd $PROJECT_ROOT
    python -m pytest -m dags --run-dag-tests -vv tests

    # docker ps -aqf "name=hadoop"
    # docker ps -aqf "name=moto"
    # docker ps -aqf "name=presto"
    exit 0
fi
