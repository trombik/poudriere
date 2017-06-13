#!/bin/sh
# 
# Copyright (c) 2010-2013 Baptiste Daroussin <bapt@FreeBSD.org>
# Copyright (c) 2010-2011 Julien Laffaye <jlaffaye@FreeBSD.org>
# Copyright (c) 2012-2014 Bryan Drewery <bdrewery@FreeBSD.org>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

usage() {
	cat << EOF
poudriere testport [parameters] [options]

Parameters:
    -j jailname -- Run inside the given jail
    [-o] origin   -- Specify an origin in the portstree

Options:
    -B name     -- What buildname to use (must be unique, defaults to
                   YYYY-MM-DD_HH:MM:SS). Resuming a previous build will not
                   retry built/failed/skipped/ignored packages.
    -c          -- Run make config for the given port
    -i          -- Interactive mode. Enter jail for interactive testing and
                   automatically cleanup when done.
    -I          -- Advanced Interactive mode. Leaves jail running with port
                   installed after test.
    -J n[:p]    -- Run n jobs in parallel for dependencies, and optionally
                   run a different number of jobs in parallel while preparing
                   the build. (Defaults to the number of CPUs for n and
                   1.25 times n for p)
    -k          -- Don't consider failures as fatal; find all failures.
    -N          -- Do not build package repository or INDEX when build
                   of dependencies completed
    -p tree     -- Specify the path to the portstree
    -P          -- Use custom prefix
    -s          -- Skip incremental rebuild and sanity checks
    -S          -- Don't recursively rebuild packages affected by other
                   packages requiring incremental rebuild. This can result
                   in broken packages if the ones updated do not retain
                   a stable ABI.
    -v          -- Be verbose; show more information. Use twice to enable
                   debug output
    -w          -- Save WRKDIR on failed builds
    -z set      -- Specify which SET to use
EOF
	exit 1
}

CONFIGSTR=0
. ${SCRIPTPREFIX}/common.sh
NOPREFIX=1
SETNAME=""
SKIPSANITY=0
SKIP_RECURSIVE_REBUILD=0
INTERACTIVE_MODE=0
PTNAME="default"
BUILD_REPO=1

while getopts "o:cniIj:J:kNp:PsSvwz:" FLAG; do
	case "${FLAG}" in
		B)
			BUILDNAME="${OPTARG}"
			;;
		c)
			CONFIGSTR=1
			;;
		o)
			ORIGINSPEC=${OPTARG}
			;;
		n)
			# Backwards-compat with NOPREFIX=1
			;;
		j)
			jail_exists ${OPTARG} || err 1 "No such jail: ${OPTARG}"
			JAILNAME="${OPTARG}"
			;;
		J)
			BUILD_PARALLEL_JOBS=${OPTARG%:*}
			PREPARE_PARALLEL_JOBS=${OPTARG#*:}
			;;
		k)
			PORTTESTING_FATAL=no
			;;
		i)
			INTERACTIVE_MODE=1
			;;
		I)
			INTERACTIVE_MODE=2
			;;
		N)
			BUILD_REPO=0
			;;
		p)
			porttree_exists ${OPTARG} ||
			    err 2 "No such ports tree ${OPTARG}"
			PTNAME=${OPTARG}
			;;
		P)
			NOPREFIX=0
			;;
		s)
			SKIPSANITY=1
			;;
		S)
			SKIP_RECURSIVE_REBUILD=1
			;;
		w)
			SAVE_WRKDIR=1
			;;
		z)
			[ -n "${OPTARG}" ] || err 1 "Empty set name"
			SETNAME="${OPTARG}"
			;;
		v)
			VERBOSE=$((${VERBOSE} + 1))
			;;
		*)
			usage
			;;
	esac
done

saved_argv="$@"
shift $((OPTIND-1))
post_getopts

if [ -z ${ORIGINSPEC} ]; then
	if [ $# -ne 1 ]; then
		usage
	fi
	ORIGINSPEC="${1}"
fi

[ -z "${JAILNAME}" ] && err 1 "Don't know on which jail to run please specify -j"
_pget portsdir ${PTNAME} mnt
originspec_decode "${ORIGINSPEC}" ORIGIN '' FLAVOR
[ "${FLAVOR}" = "${FLAVOR_DEFAULT}" ] && FLAVOR=
new_origin=$(grep -v '^#' ${portsdir}/MOVED | awk -vorigin="${ORIGIN}" \
    -F\| '$1 == origin && $2 != "" {print $2}')
if [ -n "${new_origin}" ]; then
	msg "MOVED: ${COLOR_PORT}${ORIGIN}${COLOR_RESET} moved to ${COLOR_PORT}${new_origin}${COLOR_RESET}"
	ORIGIN="${new_origin}"
fi
originspec_encode ORIGINSPEC "${ORIGIN}" '' "${FLAVOR}"
if [ ! -f "${portsdir}/${ORIGIN}/Makefile" ] || [ -d "${portsdir}/${ORIGIN}/../Mk" ]; then
	err 1 "Nonexistent origin ${COLOR_PORT}${ORIGIN}${COLOR_RESET}"
fi

maybe_run_queued "$@"

: ${BUILD_PARALLEL_JOBS:=${PARALLEL_JOBS}}
: ${PREPARE_PARALLEL_JOBS:=$(echo "scale=0; ${PARALLEL_JOBS} * 1.25 / 1" | bc)}
PARALLEL_JOBS=${PREPARE_PARALLEL_JOBS}

MASTERNAME=${JAILNAME}-${PTNAME}${SETNAME:+-${SETNAME}}
_mastermnt MASTERMNT
export MASTERNAME
export MASTERMNT
export POUDRIERE_BUILD_TYPE=bulk

jail_start ${JAILNAME} ${PTNAME} ${SETNAME}

if [ $CONFIGSTR -eq 1 ]; then
	command -v dialog4ports >/dev/null 2>&1 || err 1 "You must have ports-mgmt/dialog4ports installed on the host to use -c."
	PORTSDIR=${portsdir} \
	    PORT_DBDIR=${MASTERMNT}/var/db/ports \
	    TERM=${SAVED_TERM} \
	    make -C ${portsdir}/${ORIGIN} config \
	    ${FLAVOR:+FLAVOR=${FLAVOR}}
fi

deps_fetch_vars "${ORIGINSPEC}" LISTPORTS PKGNAME DEPENDS_ARGS FLAVOR FLAVORS
for dep_origin in ${LISTPORTS}; do
	msg_verbose "${COLOR_PORT}${ORIGINSPEC}${COLOR_RESET} depends on ${COLOR_PORT}${dep_origin}"
done
prepare_ports
markfs prepkg ${MASTERMNT}

_log_path log

POUDRIERE_BUILD_TYPE=bulk parallel_build ${JAILNAME} ${PTNAME} ${SETNAME}
if [ $(bget stats_failed) -gt 0 ] || [ $(bget stats_skipped) -gt 0 ]; then
	failed=$(bget ports.failed | awk '{print $1 ":" $3 }' | xargs echo)
	skipped=$(bget ports.skipped | awk '{print $1}' | sort -u | xargs echo)

	msg_error "Depends failed to build"
	COLOR_ARROW="${COLOR_FAIL}" \
	    msg "${COLOR_FAIL}Failed ports: ${COLOR_PORT}${failed}"
	[ -n "${skipped}" ] && COLOR_ARROW="${COLOR_SKIP}" \
	    msg "${COLOR_SKIP}Skipped ports: ${COLOR_PORT}${skipped}"

	bset_job_status "failed/depends" "${ORIGIN}"
	set +e
	exit 1
fi
nbbuilt=$(bget stats_built)

[ ${BUILD_REPO} -eq 1 -a ${nbbuilt} -gt 0 ] && build_repo

commit_packages

PARALLEL_JOBS=${BUILD_PARALLEL_JOBS}

bset_job_status "testing" "${ORIGIN}"

LOCALBASE=`injail /usr/bin/make -C ${PORTSDIR}/${ORIGIN} -VLOCALBASE`
: ${PREFIX:=$(injail /usr/bin/make -C ${PORTSDIR}/${ORIGIN} -VPREFIX)}
if [ "${USE_PORTLINT}" = "yes" ]; then
	[ ! -x `command -v portlint` ] &&
		err 2 "First install portlint if you want USE_PORTLINT to work as expected"
	msg "Portlint check"
	set +e
	cd ${MASTERMNT}${PORTSDIR}/${ORIGIN} &&
		PORTSDIR="${MASTERMNT}${PORTSDIR}" portlint -C | \
		tee ${log}/logs/${PKGNAME}.portlint.log
	set -e
fi
[ ${NOPREFIX} -ne 1 ] && PREFIX="${BUILDROOT:-/prefix}/`echo ${PKGNAME} | tr '[,+]' _`"
[ "${PREFIX}" != "${LOCALBASE}" ] && PORT_FLAGS="PREFIX=${PREFIX}"
msg "Building with flags: ${PORT_FLAGS}"

if [ -d ${MASTERMNT}${PREFIX} -a "${PREFIX}" != "/usr" ]; then
	msg "Removing existing ${PREFIX}"
	[ "${PREFIX}" != "${LOCALBASE}" ] && rm -rf ${MASTERMNT}${PREFIX}
fi

PKGENV="PACKAGES=/tmp/pkgs PKGREPOSITORY=/tmp/pkgs"
MAKE_ARGS="${FLAVOR:+ FLAVOR=${FLAVOR}}"
injail install -d -o ${PORTBUILD_USER} /tmp/pkgs
PORTTESTING=yes
export TRYBROKEN=yes
export NO_WARNING_PKG_INSTALL_EOL=yes
# Disable waits unless running in a tty interactively
if ! [ -t 1 ]; then
	export WARNING_WAIT=0
	export DEV_WARNING_WAIT=0
fi
sed -i '' '/DISABLE_MAKE_JOBS=poudriere/d' ${MASTERMNT}/etc/make.conf
if [ -n "${MAX_MEMORY_BYTES}" -o -n "${MAX_FILES}" ]; then
	JEXEC_LIMITS=1
fi
log_start 1
buildlog_start ${PORTSDIR}/${ORIGIN}
ret=0

# Don't show timestamps in msg() which goes to logs, only job_msg()
# which goes to master
NO_ELAPSED_IN_MSG=1
build_port "${ORIGINSPEC}" || ret=$?
unset NO_ELAPSED_IN_MSG

if [ ${ret} -ne 0 ]; then
	if [ ${ret} -eq 2 ]; then
		failed_phase=$(awk -f ${AWKPREFIX}/processonelog2.awk \
			${log}/logs/${PKGNAME}.log \
			2> /dev/null)
	else
		failed_status=$(bget status)
		failed_phase=${failed_status%%:*}
	fi

	save_wrkdir ${MASTERMNT} "${PKGNAME}" "${PORTSDIR}/${ORIGIN}" "${failed_phase}" || :

	ln -s ../${PKGNAME}.log ${log}/logs/errors/${PKGNAME}.log
	errortype=$(/bin/sh ${SCRIPTPREFIX}/processonelog.sh \
		${log}/logs/errors/${PKGNAME}.log \
		2> /dev/null)
	badd ports.failed "${ORIGIN} ${PKGNAME} ${failed_phase} ${errortype}"
	update_stats || :

	if [ ${INTERACTIVE_MODE} -eq 0 ]; then
		stop_build "${PKGNAME}" ${ORIGIN} 1
		log_stop
		bset_job_status "failed/${failed_phase}" "${ORIGIN}"
		msg_error "Build failed in phase: ${COLOR_PHASE}${failed_phase}${COLOR_RESET}"
		set +e
		exit 1
	fi
else
	badd ports.built "${ORIGIN} ${PKGNAME}"
	if [ -f ${MASTERMNT}${PORTSDIR}/${ORIGIN}/.keep ]; then
		save_wrkdir ${MASTERMNT} "${PKGNAME}" "${PORTSDIR}/${ORIGIN}" \
		    "noneed" || :
	fi
	update_stats || :
fi

if [ ${INTERACTIVE_MODE} -gt 0 ]; then
	# Stop the tee process and stop redirecting stdout so that
	# the terminal can be properly used in the jail
	log_stop

	# Update LISTPORTS so enter_interactive only installs the built port
	# via listed_ports()
	LISTPORTS="${ORIGINSPEC}"
	enter_interactive

	if [ ${INTERACTIVE_MODE} -eq 1 ]; then
		# Since failure was skipped earlier, fail now after leaving
		# jail.
		if [ -n "${failed_phase}" ]; then
			bset_job_status "failed/${failed_phase}" "${ORIGIN}"
			msg_error "Build failed in phase: ${COLOR_PHASE}${failed_phase}${COLOR_RESET}"
			set +e
			exit 1
		fi
	elif [ ${INTERACTIVE_MODE} -eq 2 ]; then
		exit 0
	fi
else
	if [ -f ${MASTERMNT}/tmp/pkgs/${PKGNAME}.${PKG_EXT} ]; then
		msg "Installing from package"
		ensure_pkg_installed || err 1 "Unable to extract pkg."
		injail ${PKG_ADD} /tmp/pkgs/${PKGNAME}.${PKG_EXT} || :
	fi
fi

msg "Cleaning up"
injail /usr/bin/make -C ${PORTSDIR}/${ORIGIN} -DNOCLEANDEPENDS clean \
    ${FLAVOR:+FLAVOR=${FLAVOR}}

msg "Deinstalling package"
ensure_pkg_installed
injail ${PKG_DELETE} ${PKGNAME}

stop_build "${PKGNAME}" ${ORIGIN} ${ret}
log_stop

bset_job_status "stopped" "${ORIGIN}"

bset status "done:"

set +e

exit 0
