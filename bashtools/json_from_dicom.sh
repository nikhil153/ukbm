#!/bin/bash
#SBATCH --array=0-3
#SBATCH --cpus-per-task=1
#SBATCH --ntasks=1
#SBATCH --mem-per-cpu=4096M
#SBATCH --time=1-00:00:00

# Some of the rfmri nifti files (datafield 20227) have .json files that are either not correctly-formatted, contain
# incorrect information, or are missing. The correct data can be found in the dicom files (datafield 20225).
# The dicom archives are mostly consistent, with a few exceptions. Most subjects have only the BOLD and SBref files,
# but others had false starts and don't have the same number of files or the same numbering.
# Lastly, the entry, 'TaskName' in the .json file is necessary to be BIDS-compliant.

# This script uses dcm2niix to get only the .json files, verify the content, and put the files into a BIDS-compliant
# format (matching ukbm/convert/bids.py).
# For execution without SLURM, modify the following code block to

###
module load dcm2niix
ST=${SLURM_TMPDIR}  # temporary directory

# Expect zipdir bidsdir in exported env
if [ -z "$zipdir" ]; then
	echo "zipdir undefined; define it on submission using 'sbatch --export=ALL,zipdir=ZIPDIR,bidsdir=BIDSDIR batch.sbatch'"
	exit 1
fi
if [ -z "$bidsdir" ]; then
	echo "bidsdir undefined; define it on submission using 'sbatch --export=ALL,zipdir=ZIPDIR,bidsdir=BIDSDIR batch.sbatch'"
	exit 1
fi
###

# Get list of zips
echo "Getting zips from ${zipdir}"
ziplist=(`printf "%s\n" ${zipdir}/*.zip`)
zipnum=${#ziplist[@]}
echo "Found ${zipnum} zipped files"

njob=${SLURM_ARRAY_TASK_COUNT}
jobind=${SLURM_ARRAY_TASK_ID}
nperjob=$((zipnum/njob+1))
startind=$((jobind*nperjob))
endind=$((startind+nperjob))

unziplist=${ziplist[@]:startind:endind}
echo "Taking ${#unziplist[@]} to check"

# iterate over unziplist
#  - extract manifest.* - manifest is either .csv or .cvs

for z in ${unziplist[@]}; do
	# Prepare output; extract processing info
	tmpdcm=`mktemp -d -p ${ST} dcm.XXXXXXXX`
	bufid=`basename "$z"`
	subid=${bufid%%_*}
	bufses=(${bufid//_/ })
	sess=${bufses[-2]}
	outdir="${bidsdir}/sub-${subid}/ses-${sess}/func"
	mkdir -p ${outdir}

	# extract only manifest.*
	unzip -q -p ${z} "manifest.*" > ${tmpdcm}/manifest.csv
	# get list of dcm in zipped archive
	dcmlist=(`unzip -l ${z} | grep .dcm`)

	# Column 6 contains the series name; there should only be 3.
	# Some archives have one which is missing; others have some false starts.
	numseries=`cut -d "," -f 6 ${tmpdcm}/manifest.csv | sort | uniq | wc -l`
	echo "numseries: ${numseries} for ${z}"

	if [ ${numseries} -eq 3 ] || [ ${numseries} -eq 2 ]; then
		# Expected number; extract first and last .dcm; dcm2niix BIDS header; determine which is which; convert filename to bids
		# unzip dcms
		unzip -q "${z}" "${dcmlist[3]}" "${dcmlist[-1]}" -d "${tmpdcm}/"  # dcmlist[3] because 0-2 are other files
		# get bids header
		dcm2niix -b o -o "${tmpdcm}" -f "%s" "${tmpdcm}"
		# tmpdcm now contains a .json for each series
		jsonlist=(`printf "%s\n" "${tmpdcm}/*.json"`)

		# Check which one has Multiband; no Multiband is sbref
		for j in ${jsonlist[@]}; do
		  # Add 'TaskName' to file
		  json_content=`cat ${j}`
			json_content="${json_content}, \"TaskName\": \"rest\"}"
			if [ `grep Multiband ${j} | wc -l` -eq 1 ]; then
				# bold
				echo ${json_content} > "${outdir}/sub-${subid}_ses-${sess}_task-rest_bold.json"
			else
				#sbref
				echo ${json_content} > "${outdir}/sub-${subid}_ses-${sess}_task-rest_sbref.json"
			fi
		done
	else
		# multiple series; extract everything; dcm2niix everything; determine which is which; convert
		# unzip everything
		unzip -q "${z}" -d "${tmpdcm}/"
		dcm2niix -b y -o "${tmpdcm}" "${tmpdcm}"

		# Check .json to check multiband; check .nii header to get num volumes
		niilist=(`printf "%s\n" "${tmpdcm}/*.nii"`)
		echo "niilist:"
		for n in ${niilist[@]}; do
			echo "${n}"
		done
		jsonlist=()
		lenlist=${#niilist[@]}
		
		# determine which file is desired files; check .nii
		bold_count=0
		sbref_count=0
		bold_name=''
		sbref_name=''
		for n in ${niilist[@]}; do
			echo "n: ${n}"
			
			# These two lines get the number of volumes from the Nifti-2 header and convert it from hex to dec
			diminfo=(`xxd -e -l 2 -s 48 ${n}`)  
			numvol=`printf "%d" $((16#${diminfo[1]}))`
			
			if [ ${numvol} -eq 490 ]; then  # Sequence should have 490 volumes
				# check that json file uses multiband acc (sanity check)
				jsonfile="${n%.nii}.json"
				has_multi=`grep Multiband ${jsonfile} | wc -l`
				if [ ${has_multi} -eq 1 ]; then
					# has everything we want
					bold_count=$((bold_count+1))
					bold_name=${jsonfile}
				fi
			elif [ ${numvol} -eq 1 ]; then  # Sbref should have only one volume
				jsonfile="${n%.nii}.json"
				has_multi=`grep Multiband ${jsonfile} | wc -l`
				if [ ${has_multi} -eq 0 ]; then
					sbref_count=$((sbref_count+1))
					sbref_name=${jsonfile}
				fi
			fi
		done

		# If only 1 file for BOLD and the SBref have been identified, we're done.
		if [ ${bold_count} -eq 1 ] && [ ${sbref_count} -eq 1 ]; then
			# files of interest identified; extract
			cp "${bold_name}" "${outdir}/sub-${subid}_ses-${sess}_task-rest_bold.json"
			cp "${sbref_name}" "${outdir}/sub-${subid}_ses-${sess}_task-rest_sbref.json"
		else
			# If multiple files have been found which match the criteria, do nothing and report to user.
			echo "${n}" >> ${bidsdir}/badlist.txt
		fi
	fi
done