#!/bin/bash
#
# tasks performed:
#
# - creates a local Docker image with an encrypted Python program (flask patient service) and encrypted input file
# - pushes a new session to a CAS instance
# - creates a file with the session name
#
# show what we do (-x), export all varialbes (-a), and abort of first error (-e)

set -x -a -e
trap "echo Unexpected error! See log above; exit 1" ERR

# CONFIG Parameters (might change)

export SCONE_CAS_ADDR="4-0-0.scone-cas.cf"
export DEVICE="/dev/sgx"

export CAS_MRENCLAVE="9a1553cd86fd3358fb4f5ac1c60eb8283185f6ae0e63de38f907dbaab7696794"

export CLI_IMAGE="sconecuratedimages/kubernetes:hello-k8s-scone0.1"
export PYTHON_IMAGE="sconecuratedimages/apps:python3-alpine-scone4.2.0"
export PYTHON_MRENCLAVE="a61f844dcc46be3b8cb536e5352968b587ea195c9a7ad5948d8c4d1f96c26a3c"

# create random and hence, uniquee session number
SESSION="FlaskSession-$RANDOM-$RANDOM-$RANDOM"

# create directories for encrypted files and fspf
rm -rf encrypted-files
rm -rf native-files
rm -rf fspf-file

mkdir native-files/
mkdir encrypted-files/
mkdir fspf-file/
cp fspf.sh fspf-file
cp rest_api.py native-files/

# ensure that we have an up-to-date image
docker pull $CLI_IMAGE

# check if SGX device exists

if [[ ! -c "$DEVICE" ]] ; then 
    export DEVICE_O="DEVICE"
    export DEVICE="/dev/isgx"
    if [[ ! -c "$DEVICE" ]] ; then 
        echo "Neither $DEVICE_O nor $DEVICE exist"
        exit 1
    fi
fi


# attest cas before uploading the session file, accept CAS running in debug
# mode (-d) and outdated TCB (-G)
docker run --device=$DEVICE -it $CLI_IMAGE sh -c "
scone cas attest -G --only_for_testing-debug  scone-cas.cf $CAS_MRENCLAVE >/dev/null \
&&  scone cas show-certificate" > cas-ca.pem

# create encrypte filesystem and fspf (file system protection file)
docker run --device=$DEVICE  -it -v $(pwd)/fspf-file:/fspf/fspf-file -v $(pwd)/native-files:/fspf/native-files/ -v $(pwd)/encrypted-files:/fspf/encrypted-files $CLI_IMAGE /fspf/fspf-file/fspf.sh

cat >Dockerfile <<EOF
FROM $PYTHON_IMAGE

COPY encrypted-files /fspf/encrypted-files
COPY fspf-file/fs.fspf /fspf/fs.fspf
COPY requirements.txt requirements.txt
RUN pip3 install -r requirements.txt
EOF

# create a image with encrypted flask service
docker build --pull -t flask_restapi_image .

# ensure that we have self-signed client certificate

if [[ ! -f client.pem || ! -f client-key.pem  ]] ; then
    openssl req -newkey rsa:4096 -days 365 -nodes -x509 -out client.pem -keyout client-key.pem -config clientcertreq.conf
fi

# create session file

export SCONE_FSPF_KEY=$(cat native-files/keytag | awk '{print $11}')
export SCONE_FSPF_TAG=$(cat native-files/keytag | awk '{print $9}')

MRENCLAVE=$PYTHON_MRENCLAVE envsubst '$MRENCLAVE $SCONE_FSPF_KEY $SCONE_FSPF_TAG $SESSION' < session-template.yml > session.yml
# note: this is insecure - use scone session create instead
curl -v -k -s --cert client.pem  --key client-key.pem  --data-binary @session.yml -X POST https://$SCONE_CAS_ADDR:8081/session


# create file with environment variables

cat > myenv << EOF
export SESSION="$SESSION"
export SCONE_CAS_ADDR="$SCONE_CAS_ADDR"
export DEVICE="$DEVICE"

EOF

echo "OK"
