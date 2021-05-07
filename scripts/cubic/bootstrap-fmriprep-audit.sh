## NOTE ##
# This workflow is derived from the Datalad Handbook

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/fmriprep-audit
if [[ -d ${PROJECTROOT} ]]
then
    echo ${PROJECTROOT} already exists
    # exit 1
fi

if [[ ! -w $(dirname ${PROJECTROOT}) ]]
then
    echo Unable to write to ${PROJECTROOT}\'s parent. Change permissions and retry
    # exit 1
fi
FMRIPREP_INPUT=$1
if [[ -z ${FMRIPREP_INPUT} ]]
then
    echo "Required argument is an identifier of the datalad dataset with fmriprep/freesurfer outputs"
    # exit 1
fi

# Is it a directory on the filesystem?
FMRIPREP_INPUT_METHOD=clone
if [[ -d "${FMRIPREP_INPUT}" ]]
then
    # Check if it's datalad
    FMRIPREP_DATALAD_ID=$(datalad -f '{infos[dataset][id]}' wtf -S \
                      dataset -d ${FMRIPREP_INPUT} 2> /dev/null || true)
    [ "${FMRIPREP_DATALAD_ID}" = 'N/A' ] && FMRIPREP_INPUT_METHOD=copy
fi

# Check that there are some fmriprep zip files present in the input
# If you only need freesurfer, comment this out
FMRIPREP_ZIPS=$(cd ${FMRIPREP_INPUT} && ls *fmriprep*.zip)
if [[ -z "${FMRIPREP_ZIPS}" ]]; then
   echo No fmriprep zip files found in ${FMRIPREP_INPUT}
   exit 1
fi

# Check that freesurfer data exists. If you only need fmriprep zips, comment
# this out
# FREESURFER_ZIPS=$(cd ${FMRIPREP_INPUT} && ls *freesurfer*.zip)
# if [[ -z "${FREESURFER_ZIPS}" ]]; then
#    echo No freesurfer zip files found in ${FMRIPREP_INPUT}
#    exit 1
# fi

## Start making things
mkdir -p ${PROJECTROOT}
cd ${PROJECTROOT}

# Jobs are set up to not require a shared filesystem (except for the lockfile)
# ------------------------------------------------------------------------------
# RIA-URL to a different RIA store from which the dataset will be cloned from.
# Both RIA stores will be created
input_store="ria+file://${PROJECTROOT}/input_ria"
output_store="ria+file://${PROJECTROOT}/output_ria"

# Create a source dataset with all analysis components as an analysis access
# point.
datalad create -c yoda analysis
cd analysis

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"

# register the input dataset
if [[ "${FMRIPREP_INPUT_METHOD}" == "clone" ]]
then
    echo "Cloning input dataset into analysis dataset"
    datalad clone -d . ${FMRIPREP_INPUT} inputs/data
    # amend the previous commit with a nicer commit message
    git commit --amend -m 'Register input data dataset as a subdataset'
else
    echo "WARNING: copying input data into repository"
    mkdir -p inputs/data
    cp -r ${FMRIPREP_INPUT}/* inputs/data
    datalad save -r -m "added input data"
fi

SUBJECTS=$(find inputs/data -name '*.zip' | cut -d '/' -f 3 | cut -d '_' -f 1 | sort | uniq)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi


## Add the containers as a subdataset
cd ${PROJECTROOT}

# Clone the containers dataset. If specified on the command, use that path
CONTAINERDS=$2
if [[ ! -z "${CONTAINERDS}" ]]; then
    datalad clone ${CONTAINERDS} pennlinc-containers
else
    echo "No containers dataset specified, attempting to clone from pmacs"
    datalad clone \
        ria+ssh://sciget.pmacs.upenn.edu:/project/bbl_projects/containers#~pennlinc-containers \
        pennlinc-containers
fi

# download the image so we don't ddos pmacs
cd pennlinc-containers
datalad get -r .
cd ${PROJECTROOT}/analysis
datalad install -d . --source ${PROJECTROOT}/pennlinc-containers

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=5G
#$ -l s_vmem=3.5G
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

# Set up the remotes and get the subject id from the call
dssource="$1"
pushgitremote="$2"
subid="$3"

# change into the cluster-assigned temp directory. Not done by default in SGE
cd ${CBICA_TMPDIR}

# Used for the branch names and the temp dir
BRANCH="job-${JOB_ID}-${subid}"
mkdir ${BRANCH}
cd ${BRANCH}

# get the analysis dataset, which includes the inputs as well
# importantly, we do not clone from the lcoation that we want to push the
# results to, in order to avoid too many jobs blocking access to
# the same location and creating a throughput bottleneck
datalad clone "${dssource}" ds

# all following actions are performed in the context of the superdataset
cd ds

# in order to avoid accumulation temporary git-annex availability information
# and to avoid a syncronization bottleneck by having to consolidate the
# git-annex branch across jobs, we will only push the main tracking branch
# back to the output store (plus the actual file content). Final availability
# information can be establish via an eventual `git-annex fsck -f joc-storage`.
# this remote is never fetched, it accumulates a larger number of branches
# and we want to avoid progressive slowdown. Instead we only ever push
# a unique branch per each job (subject AND process specific name)
git remote add outputstore "$pushgitremote"

# all results of this job will be put into a dedicated branch
git checkout -b "${BRANCH}"

# we pull down the input subject manually in order to discover relevant
# files. We do this outside the recorded call, because on a potential
# re-run we want to be able to do fine-grained recomputing of individual
# outputs. The recorded calls will have specific paths that will enable
# recomputation outside the scope of the original setup
datalad get -n "inputs/data/${subid}*fmriprep*.zip"

# ------------------------------------------------------------------------------
# Do the run!
datalad run \
    -i code/fmriprep_zip_audit.sh \
    -i inputs/data/${subid}*fmriprep*.zip \
    --explicit \
    -o ${subid}_fmriprep-audit.csv \
    -m "fmriprep-audit ${subid}" \
    "./code/fmriprep_zip_audit.sh ${subid}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

echo SUCCESS
# job handler should clean up workspace
EOT

chmod +x code/participant_job.sh

cat > code/fmriprep_zip_audit.sh << "EOT"
#!/bin/bash
set -e -u -x

# zips will be in inputs/data
subid="$1"
python code/audit_fmriprep.py ${subid}

EOT

chmod +x code/fmriprep_zip_audit.sh

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"
################################################################################
# SGE SETUP START - remove or adjust to your needs
################################################################################
cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT

echo "outputsource=${output_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)" \
    >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh

cat >> code/merge_outputs.sh << "EOT"
datalad clone ${outputsource} merge_ds
cd merge_ds
NBRANCHES=$(git branch -a | grep job- | sort | wc -l)
echo "Found $NBRANCHES branches to merge"

gitref=$(git show-ref master | cut -d ' ' -f1 | head -n 1)

# query all branches for the most recent commit and check if it is identical.
# Write all branch identifiers for jobs without outputs into a file.
for i in $(git branch -a | grep job- | sort); do [ x"$(git show-ref $i \
  | cut -d ' ' -f1)" = x"${gitref}" ] && \
  echo $i; done | tee code/noresults.txt | wc -l


for i in $(git branch -a | grep job- | sort); \
  do [ x"$(git show-ref $i  \
     | cut -d ' ' -f1)" != x"${gitref}" ] && \
     echo $i; \
done | tee code/has_results.txt

mkdir -p code/merge_batches
num_branches=$(wc -l < code/has_results.txt)
CHUNKSIZE=5000
num_chunks=$(expr ${num_branches} / ${CHUNKSIZE})
[[ $num_chunks == 0 ]] && num_chunks=1
for chunknum in $(seq 1 $num_chunks)
do
    startnum=$(expr $(expr ${chunknum} - 1) \* ${CHUNKSIZE} + 1)
    endnum=$(expr ${chunknum} \* ${CHUNKSIZE})
    batch_file=code/merge_branches_$(printf %04d ${chunknum}).txt
    [[ ${num_branches} -lt ${endnum} ]] && endnum=${num_branches}
    branches=$(sed -n "${startnum},${endnum}p;$(expr ${endnum} + 1)q" code/has_results.txt)
    echo ${branches} > ${batch_file}
    git merge -m "fmriprep results batch ${chunknum}/${num_chunks}" $(cat ${batch_file})

done

# Push the merge back
git push

# Get the file availability info
git annex fsck --fast -f output-storage

# This should not print anything
MISSING=$(git annex find --not --in output-storage)

if [[ ! -z "$MISSING"]]
then
    echo Unable to find data for $MISSING
    exit 1
fi

# stop tracking this branch
git annex dead here
datalad push --data nothing
echo SUCCESS

EOT


env_flags="-v DSLOCKFILE=${PWD}/.SGE_datalad_lock"

echo '#!/bin/bash' > code/qsub_calls.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
for subject in ${SUBJECTS}; do
  echo "qsub -cwd ${env_flags} -N fp${subject} ${eo_args} \
  ${PWD}/code/participant_job.sh \
  ${dssource} ${pushgitremote} ${subject} " >> code/qsub_calls.sh
done
datalad save -m "SGE submission setup" code/ .gitignore

################################################################################
# SGE SETUP END
################################################################################

# cleanup - we have generated the job definitions, we do not need to keep a
# massive input dataset around. Having it around wastes resources and makes many
# git operations needlessly slow
if [ "${FMRIPREP_INPUT_METHOD}" = "clone" ]
then
    datalad uninstall -r --nocheck inputs/data
fi

# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# if we get here, we are happy
echo SUCCESS