#!/bin/bash

DATA=$(pwd)
PROJECTROOT=$DATA/fcon
mkdir $PROJECTROOT
cd $PROJECTROOT

# set up concat_ds and run concatenator on it
datalad clone ria+file://$DATA/matrices/output_ria#~data concat_ds
cd concat_ds/code
wget https://raw.githubusercontent.com/PennLINC/RBC/master/PennLINC/Generic/matrix_concatenator.py
cd $PROJECTROOT
datalad save -m "added matrix concatenator script"
datalad run -i '*matrices.zip*' -o 'concat_ds/group_matrices.zip' --expand inputs --explicit "python code/concatenator.py"

# push changes
datalad save -m "generated concatenated matrices"
datalad push

# remove concat_ds
git annex dead here
chmod +w -R concat_ds
rm -rf concat_ds

# create alias
RIA_DIR=$(find $PROJECTROOT/output_ria/???/ -maxdepth 1 -type d | sort | tail -n 1)
echo $RIA_DIR
mkdir -p ${PROJECTROOT}/output_ria/alias
ln -s ${RIA_DIR} ${PROJECTROOT}/output_ria/alias/data

echo SUCCESS
