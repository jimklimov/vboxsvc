#!/usr/bin/bash
#
# Started by Alexandre Dumont:
#   http://adumont.serveblog.net/2009/09/01/virtualbox-smf-2/
# Maintained by Jim Klimov at:
#   http://vboxsvc.sourceforge.net/
#
# This SMF method is distributed under the following MIT License terms:
#
# Copyright (c) 2009 Alexandre Dumont
# Copyright (C) 2009 minor patches by Jim Klimov to start "saved" machines
# Copyright (C) 2010-2015 larger patches by Jim Klimov, JCS COS&HT
#	$Id: vbox.sh,v 1.96 2019/03/10 13:00:33 jim Exp $
#	* process aborted, paused VM's
#	* "vm/debug_smf" flag, "vm/nice" flag.
#	* Inherit service-level default attribute values.
#	* KICKER to monitor VirtualBox VM state and restart or force
#	  SMF-maintenance state
#	  NOTE: this script can cause SMF "offline" state for service instance
#	  (not easily noticeable "maintenance") in cases that the VM became
#	  'paused', 'saved', 'poweroff' and appropriate 'vm/restart_X_vm'
#	  SMF property flags are not true, or VM got into unknown state.
#	  The offline state is temporary (i.e. until reboot). It can be set
#	  only if the execution user has RBAC rights to change SMF service
#	  state with svcadm. If that fails, script causes 'maintenance' mode.
#	** Special flag 'vm/offline_is_maint = true' causes the service to
#	  always go into SMF 'maintenance' mode, even if it can technically
#	  go 'offline'.
#	* Setting of a timezone value to change the VM's "hardware clock" zone
#	  i.e. to UTC for all server VMs regardless of host OS's default TZ
#	* Command-line mode (startgui option) to intercept a VM into GUI mode,
#	  then return it to SMF execution or (startgui -fg) to properly shut
#	  down or savestate the VM when the script is killed (interactive VMs)
#	* Hook to a procedure (some ext script) to check states of services
#	  running inside the VM (i.e. ping, check website or DB) and react
#	  by reset or maintenance... See $KICKER_VMSVCCHECK_* params.
#	* Graceful Poweroff/Reboot/Quick Reset actions
#	* Create ZFS snapshots (if enabled) before starting/after stopping VM
#	  The feature is OFF BY DEFAULT because it can consume space without
#	  control and it "is possible" that backends are not ZFS-based.
#	  Removing the old snapshots is the user's task (adapt zfs-auto-snap?)
#	* Connect to VM serial console (using socat client to the pipe file)
#    NOTE: Some features require GNU date (gdate) or perl in PATH, see $GDATE
#    and timestamping-method detector below, and socat for serial consoles.
#
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

# Ensure we're using a pretty normal PATH by default; some utilities require
# Sun versions of tools (df); others may need GNU (gdate)
PATH="\
/bin:/usr/bin:/usr/local/bin:\
/sbin:/usr/sbin:/usr/local/bin:\
/opt/sfw/bin:/usr/sfw/bin:\
/opt/gnu/bin:/usr/gnu/bin:\
$PATH"
export PATH

# Ensure programs return english text in case we want to parse and interpret
LANG=C
LC_ALL=C
export LANG
export LC_ALL

printHelp() {
    echo "vboxsvc, an SMF method for VirtualBox: (C) 2010-2015 by Jim Klimov,"
    echo '	$Id: vbox.sh,v 1.96 2019/03/10 13:00:33 jim Exp $'
    echo "	see http://vboxsvc.sourceforge.net/ for possible updates"
    echo "	building upon work (C) 2009 by Alexandre Dumont"
    echo "This method script supports SMF methods: { start | stop }"
    echo "Requires set SMF_FMRI environment variable which points to a VM instance."
    echo "VMs may be owned and run by unprivileged users, in local or global zones."
    echo ""
    echo "The KICKER loop to watch VM state re-reads variables each cycle, so"
    echo "'svccfg -s VM_NAME ... ; svcadm refresh VM_NAME' works dynamically."
    echo ""
    echo "Possible command-line options to specify VM_NAME (ultimately SMF_FMRI):"
    echo "	-s|-svc SVC_URL	SMF service name, possibly an SMF shortcut name"
    echo "	-vm VM_NAME    	'VM_NAME', as the SMF instance name (suffix after colon)"
    echo "For reboot/poweroff methods you can specify timeout override to stop faster:"
    echo "	-t timeout	Seconds, to be used instead of defaults/smf timeouts"
    echo ""
    echo "This script also supports following command-line mode methods:"
    echo ""
    echo "	getstate|state|status	Prints states of SMF service (and spawned"
    echo "				processes if any - VMs may be parented by"
    echo "				VBoxSVC outside ot service's scope) and"
    echo "				state of VM (according to VirtualBox)"
    echo "		returns 0	VM running/starting/restoring"
    echo "			1	VM paused"
    echo "			2	VM saving"
    echo "			3	VM saved"
    echo "			10	VM powered off (halted)"
    echo "			20	VM aborted (VBox process died badly)"
    echo "			125	VM state string is empty (VBox bug)"
    echo "			126	VM state unknown by script"
    echo ""
    echo "	vmsvccheck|hook		Runs the monitoring script (if assigned) to"
    echo "				test the VM's services working state as"
    echo "				defined by local admin who made the script."
    echo "		returns 0	VM test succceeded or not configured"
    echo "			1	VM test failed, KICKER would bump counter"
    echo "			2	VM test failed, KICKER would reboot VM"
    echo "			3	VM test failed, KICKER would cause SMF failure"
    echo ""
    echo "	start-force		Starts a VM even if its SMF autostart says 'no'"
    echo "	startgui (req: DISPLAY)	Saves VM state if needed, (re)starts with GUI"
    echo "				(as a background process by default, so script"
    echo "				returns your shell)"
    echo "	startgui -fg (-stop_method=X)	ditto, but don't return to shell and"
    echo "				try to catch signals to gracefully save/stop"
    echo "				the VM with the configured in SMF or requested"
    echo "				stop_method if the caller (X11 session) dies"
    echo "		NOTES: startgui also accepts any VirtualBox double-dash params"
    echo "		such as --fullscreen or --seamless, and -t for shutdown timeout"
    echo ""
    echo "	zfssnap [comment]	Snapshots VM-related ZFS datasets according"
    echo "				to SMF config (forces zfssnap_flag=true)"
    echo "	dirlist			Lists VM-related FS objects (including those"
    echo "				found automatically and implied by SMF config)"
    echo ""
    echo "	poweroff [-k]		Powers off the VM by trying"
    echo "				acpipowerbutton -> poweroff"
    echo "				Probably disrupts GUI due to VM process exit"
    echo "				The 'poweroff -k' follows up thoroughly by a kill"
    echo "				NOTE: Consider also using -t to reduce timeouts"
    echo "	reboot [-k] [ifruns]	(Conditionally) Reboots the VM by trying"
    echo "				acpipowerbutton -> poweroff -> reset -> start"
    echo "				Probably disrupts GUI due to VM process exit"
    echo "	reset			Resets the VM OS by trying reset action"
    echo "		NOTE that for VBox 3.0.12 sometimes the reset'ed Windows guest"
    echo "		VM's hang on boot while poweroff-poweron'ed ones start ok"
    echo "	save|savestate		Causes the VM to save its state (and take zfs"
    echo "				snapshots if appropriate) even if the SMF's"
    echo "				property vm/stop_method dictates otherwise"
    echo ""
    echo "NOTE: The sercon methods require 'socat' in PATH (at least for now)!"
    echo "	sercon [-f file|-u num|freq]	Opens a serial console connection on the"
    echo "				specified pipe (host file) or UART port number"
    echo "				(VM, 1-based). By default tries to detect UART"
    echo "				ports from VM config; IFF one is a 'server' -"
    echo "				uses it. Of course, the guest boot-loader and"
    echo "				OS must be configured to process IO on that"
    echo "				virtual serial port. Loops until broken, with"
    echo "				5 (or 'freq') seconds of sleep between retries -"
    echo "				good to survive those VM reboots which close"
    echo "				the VM serial port connection."
    echo "	sercon-once [-f file|-u num]	Same as above, but no loop - one shot"
    echo "	sercon-break		Kills the sercon client for this VM, because"
    echo "				it is problematic to close it 'from inside'"
    echo "				interactively."
    echo ""

}

#############################################################################
### Small helper routines
echodot() {
    /bin/echo ".\c"
}

echo_noret() {
    ### Echoes "$@" without carriage return/linefeed if possible...
    /bin/echo "$@\c"
}

sleeper() {
    ### Simple routine for breakable sleep (i.e. for background processes)
    MAX="$1"
    [ -z "$MAX" -o "$MAX" -le 0 ] && MAX=1

    COUNT=0
    while [ "$COUNT" -lt "$MAX" ]; do
	sleep 1
	COUNT="`expr $COUNT + 1`"
    done
}
#############################################################################

### This allows to make simple symlinks to the vbox.sh script in order to start
### interactive VMs (in their own xterm's for the foreground management script)
### i.e. from a GNOME panel launcher. The xterm is launched into background.
### NOTE that in this mode any command-line params are ignored; the VM name
### and optional shutdown mode override are passed as parts of symlink name:
###    vbox-startgui:ubuntu:poweroff-graceful:30 -> /lib/svc/method/vbox.sh
### NOTE that this xterm must be closed by hand (or some script) BEFORE you
### log out of your X11 session, in order to properly save or shut down the VM!
### (Otherwise it dies ungracefully without X11 canvas, and becomed "aborted")
BASENAME_TWEAK=${BASENAME_TWEAK:-true}
[ x"$BASENAME_TWEAK" = xtrue ] && case "`basename "$0"`" in
    vbox-startgui-fg\:*|vbox-startgui\:*)
	INSTANCE="${INSTANCE:-`basename $0 | sed 's/^[^:]*://'`}" || INSTANCE=""
	[ x"$INSTANCE" = x ] && \
		echo "BASENAME_TWEAK: No VM instance selected by script name!" \
		&& exit 1

	STOP_METHOD="${STOP_METHOD:-}"
	STOP_TIMEOUT="${STOP_TIMEOUT:-}"
	case "$INSTANCE" in
	    *\:*)
		STOP_METHOD="`echo "$INSTANCE" | sed 's/^[^:]*://'`"
		INSTANCE="`echo "$INSTANCE" | sed 's/:.*$//'`"
		;;
	esac
	case "$STOP_METHOD" in
	    *\:*)
		STOP_TIMEOUT="`echo "$STOP_METHOD" | sed 's/^[^:]*://'`"
		STOP_METHOD="`echo "$STOP_METHOD" | sed 's/:.*$//'`"
		;;
	esac
	echo "BASENAME_TWEAK: Will try to manage VM '$INSTANCE'"
	[ x"$STOP_METHOD" != x ] && \
		echo "BASENAME_TWEAK: overriding stop method to '$STOP_METHOD'"
	[ x"$STOP_TIMEOUT" != x ] && \
		echo "BASENAME_TWEAK: overriding stop timeout to '$STOP_TIMEOUT''"

	BASENAME_TWEAK=false
	export BASENAME_TWEAK
	exec xterm -sb -rightbar -geom 132x10 -title "VirtualBox: $INSTANCE" \
		-e "$0" -s "$INSTANCE" startgui \
		${STOP_METHOD:+-stop_method $STOP_METHOD} \
		${STOP_TIMEOUT:+-t $STOP_TIMEOUT} \
		-fg &
	exit
	;;
esac

SCRIPT_MODE=script
[ x"$SMF_FMRI" != x ] && SCRIPT_MODE=smf

### If enabled, kill the VM process when 'poweroff -k' or 'reboot -k' are used
KILL_VM_PROCESS=no

while [ $# -gt 1 ]; do
    ### NOTE: We leave last param for normal processing below
    case "$1" in
	help|--help|-help|-h|'-?'|'/?')
	    printHelp
	    ;;
	-s|-svc) [ -z "$SMF_FMRI" ] && SMF_FMRI="$2"
	    shift 1 ;;
	-vm) [ -z "$SMF_FMRI" ] && SMF_FMRI="svc:/site/xvm/vbox:$2"
	    shift 1 ;;
	-t) VBOXSVC_TIMEOUT_OVERRIDE="$2"
	    if [ x"$VBOXSVC_TIMEOUT_OVERRIDE" != x \
		-a "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
		[ x"$DEBUG_SMF" = xtrue ] && echo "INFO: Overriding poweroff timeout: '$VBOXSVC_TIMEOUT_OVERRIDE'" >&2
	    else
		echo "WARN: Invalid timeout value '$VBOXSVC_TIMEOUT_OVERRIDE' ignored" >&2
		VBOXSVC_TIMEOUT_OVERRIDE=-1
	    fi
	    shift ;;
	startgui|start-gui|reboot|poweroff|sercon*|zfssnap)
		### This presumably begins other script parameters
		### parsed below, now break this particular cycle
	    break ;;
	*)  echo "WARN: Unrecognized command-line parameter: '$1'"
	    sleep 3 ;;
    esac
    shift 1
done

### Failure to include this is fatal, by design - no SMF installed
if [ ! -f /lib/svc/share/smf_include.sh -o \
     ! -r /lib/svc/share/smf_include.sh -o \
     ! -s /lib/svc/share/smf_include.sh ]; then
    echo "ERROR: SMF not installed? Can't use file /lib/svc/share/smf_include.sh" >&2
    exit 95
fi
. /lib/svc/share/smf_include.sh || exit 95

### Just in case, define the values we need if they are missing
[ -z "SMF_EXIT_OK" ] && SMF_EXIT_OK=0
[ -z "SMF_EXIT_ERR_FATAL" ] && SMF_EXIT_ERR_FATAL=95
[ -z "SMF_EXIT_ERR_CONFIG" ] && SMF_EXIT_ERR_CONFIG=96
[ -z "SMF_EXIT_ERR_PERM" ] && SMF_EXIT_ERR_PERM=100

if [ $# -lt 1 ]; then
    echo "ERROR on command-line: no params left to work with!" >&2
    printHelp
    exit $SMF_EXIT_ERR_CONFIG
fi
SCRIPT_METHOD="$1"

### SMF_FMRI is the name of the target service. This allows multiple instances
### to use the same script.

if [ -z "$SMF_FMRI" ]; then
    case "$1" in
	help|--help|-help|-h|'-?'|'/?')
	    printHelp
	    echo "NOTE:	SMF framework variables are not initialized."
	    echo "	A valid SMF_FMRI value is required, i.e.:"
	    svcs -a | grep 'svc:/site/xvm/vbox'
	    exit 0
	    ;;
	*)
	    echo "ERROR: SMF framework variables are not initialized." >&2
	    exit $SMF_EXIT_ERR_CONFIG
	    ;;
    esac
fi

### Sanity check for accepted external variables
OUT="`svcs -H $SMF_FMRI`"
RES=$?

if [ "$RES" != 0 -o `echo "$OUT" | wc -l` != 1 ]; then
    echo "ERROR: Provided SMF_FMRI value does not point to one SMF service name" >&2
    echo "	SMF_FMRI = '$SMF_FMRI'" >&2
    echo "	svcs check: result = '$RES', output =" >&2
    echo "===" >&2
    echo "$OUT" >&2
    echo "===" >&2
    echo "ERROR: SMF framework variables are not initialized properly." >&2
    exit $SMF_EXIT_ERR_CONFIG
fi

_SMF_FMRI="`echo "$OUT" | awk '{print $NF}'`"
if [ x"$_SMF_FMRI" != x"$SMF_FMRI" ]; then
    echo "INFO: Replacing SMF_FMRI value from '$SMF_FMRI' to '$_SMF_FMRI'"
    SMF_FMRI="$_SMF_FMRI"
fi
unset _SMF_FMRI

SMF_BASE="`echo "$SMF_FMRI" | sed 's/^\(.*\:.*\)\(\:.*\)$/\1/'`"
INSTANCE="$( echo $SMF_FMRI | cut -d: -f3 )"

##############################################################################
### If current user differs from 'method_context/user', try using 'su'
### Processed below. Use-case: root checking non-root's VM status.
RUNAS=""

getUID() {
    ### Returns the numerical UID of current user or of username in $1 if any
    ### OpenSolaris boasts a more functional "id" than Solaris 10 (u6 - u8)
    NUM_UID="`id -u $1 2>/dev/null`" || NUM_UID="`id $1 | sed 's/uid=\([^(]*\)(\([^)]*\).*$/\1/'`"
    RET=$?

    echo "$NUM_UID"
    return $RET
}

getUNAME() {
    ### Returns the string representation of the user's name
    [ "$1" -ge 0 ] 2>/dev/null && NUM_UID="$1" || NUM_UID="`getUID $1`" || return
    [ x"$NUM_UID" != x ] || return
    STR_UID="`getent passwd "$NUM_UID"`" || return
    echo "$STR_UID" | sed 's/^\([^:]*\):.*$/\1/' | head -1
}

GETPROPARG_QUIET=false
GETPROPARG_INHERIT=true
getproparg() {
    if [ x"$GETPROPARG_QUIET" = x"true" ]; then
	val="`$RUNAS svcprop -p "$1" "$SMF_FMRI" 2>/dev/null`"
    else
	val="`$RUNAS svcprop -p "$1" "$SMF_FMRI"`"
    fi

    if [ x"$val" = x"''" -o x"$val" = x'""' ]; then
	[ x"$GETPROPARG_QUIET" = x"true" ] || echo "INFO: Using instance-level attribute '$1' value explicitly set to empty ($val)" >&2
	val=""
	echo ""
	return
    fi

    [ -n "$val" ] && echo "$val" && return

    if [ x"$GETPROPARG_INHERIT" = xfalse ]; then
	false
	return
    fi

    ### Value not defined/set for instance
    ### Fetch one set for SMF service defaults
    if [ x"$GETPROPARG_QUIET" = x"true" ]; then
	val="`$RUNAS svcprop -p "$1" "$SMF_BASE" 2>/dev/null`"
    else
	val="`$RUNAS svcprop -p "$1" "$SMF_BASE"`"
    fi

    if [ -n "$val" ]; then
	[ x"$GETPROPARG_QUIET" != x"true" ] && \
	    echo "INFO: Using service-general default attribute '$1' = '$val'" >&2

	if [ x"$val" = x"''" -o x"$val" = x'""' ]; then
	    [ x"$GETPROPARG_QUIET" = x"true" ] || echo "INFO: Using service-general attribute '$1' value explicitly set to empty ($val)" >&2
	    val=""
	fi

	echo "$val"
	return
    fi
    false
}

get_nicerun() {
    ### Gets the NICE value and provides a variable to call
    ### "/bin/nice" with needed params
    NICE="$( getproparg vm/nice )"
    NICERUN=""

    if [ x"$NICE" != x ]; then
	if [ "$NICE" -le 0 -o "$NICE" -ge 0 ]; then
	    ### Is a number
	    NICERUN="/bin/nice -n $NICE"
	else
	    echo "WARN: invalid 'vm/nice' = '$NICE', ignored." >&2
	fi
    else
	echo "WARN: 'vm/nice' not set, using OS defaults." >&2
    fi

    echo "$NICERUN"
}

get_tz_vm() {
    TZ_VM="$( getproparg vm/timezone )"

    [ x"$TZ_VM" = x ] && return
    [ x"$TZ_VM" = x"''" ] && return
    [ x"$TZ_VM" = x'""' ] && return

    if [ x"$TZ" != x"$TZ_VM" ]; then
	echo "INFO: Replacing VM time zone from current '$TZ' to '$TZ_VM'" >&2
	echo "TZ='$TZ_VM'"
    else
	[ x"$DEBUG_SMF" = xtrue ] && \
	    echo "INFO: Using current time zone for VM: TZ='$TZ'" >&2
    fi
}

resume_vm() {
    # For paused VM's
    zfssnap "$1" "preresume"

    NICERUN="`get_nicerun`"
    echo "INFO: NICERUN='$NICERUN'" >&2

    ( TZVM="`get_tz_vm`"    
      [ x"$TZVM" != x ] && export $TZVM
      $RUNAS $NICERUN /usr/bin/VBoxManage controlvm "$1" resume
    )
}

start_vm() {
    zfssnap "$1" "prestart"

    NICE="$( GETPROPARG_QUIET=true getproparg vm/nice )"
    NICERUN="`get_nicerun`"

    ( TZVM="`get_tz_vm`"    
      [ x"$TZVM" != x ] && export $TZVM

	### According to docs, a headless VM always enables RDP by default
	### unless instructed otherwise. The config option name has changed
	### between VirtualBox 3.x and 4.x releases (--vrdp vs. --vrde).
	### We still want to trust whatever is in the config file for the VM.
	### Also, in a GPL build the option may be absent altogether - skip
	### it then...

      _VRDP_FLAG=""
      _HELP="`LANG=C LC_ALL=C /usr/bin/VBoxHeadless --help 2>&1`"
      echo "$_HELP" | \
	grep vrdp > /dev/null 2> /dev/null && _VRDP_FLAG="--vrdp config"
      echo "$_HELP" | \
	grep vrde > /dev/null 2> /dev/null && _VRDP_FLAG="--vrde config"

      if [ x"$NICERUN" = x -o x"$NICE" = x -o x"$NICE" = x0 ]; then
	NICERUN=""
	echo "INFO: Normal RUN;	$TZVM" >&2
      else
	echo "INFO: NICERUN; $TZVM" >&2
      fi
      echo   "	$RUNAS $NICERUN /usr/bin/VBoxHeadless --startvm '$1' $_VRDP_FLAG"

      $RUNAS $NICERUN /usr/bin/VBoxHeadless --startvm "$1" $_VRDP_FLAG &
    )
}

stop_vm() {
    ### STOP_METHOD=acpipowerbutton|savestate|acpisleepbutton|poweroff
    ### Additional non-VirtualBox methods: reset|poweroff-graceful
    if [ x"$FORCE_STOP_METHOD" != x ]; then
	STOP_METHOD="$FORCE_STOP_METHOD"
    else
	if [ x"$IS_DUALBOOT" = xtrue ]; then
		STOP_METHOD="$( GETPROPARG_INHERIT=false getproparg vm/stop_method )" || \
			STOP_METHOD=""
		[ x"$STOP_METHOD" = x ] && STOP_METHOD="poweroff-graceful"
	else
		STOP_METHOD="$( getproparg vm/stop_method )"
	fi
    fi

    case "$STOP_METHOD" in
	acpipowerbutton|savestate|acpisleepbutton|poweroff|reset)
	    ;;
	poweroff-graceful)
	    poweroff_vm "$INSTANCE"
	    return
	    ;;
	*)
	    STOP_METHOD="savestate"
	    ;;
    esac

    ( TZVM="`get_tz_vm`"    
      [ x"$TZVM" != x ] && export $TZVM
      echo "INFO: Using STOP_METHOD='$STOP_METHOD'..."
      $RUNAS /usr/bin/VBoxManage controlvm "$1" "$STOP_METHOD"
    )
    RES=$?

    if [ "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
	STOP_TIMEOUT="$VBOXSVC_TIMEOUT_OVERRIDE"
    else
	STOP_TIMEOUT="`( getproparg vm/stop_timeout )`" || STOP_TIMEOUT="-1"
	[ x"$STOP_TIMEOUT" = x ] && STOP_TIMEOUT="-1"
    fi
    STOP_METHOD_TIMEOUT="$( GETPROPARG_QUIET=true getproparg stop/timeout_seconds)" || \
	STOP_METHOD_TIMEOUT="UNDEF"
    if [ "$STOP_TIMEOUT" -le 0 ]; then
	echo "INFO: Method script will not enforce a stop timeout (vm/stop_timeout undefined). SMF may (stop/timeout_seconds=$STOP_METHOD_TIMEOUT)..."
    else
	if [ "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
	    echo "INFO: Method script will enforce a stop timeout override of $STOP_TIMEOUT, SMF may have another opinion (stop/timeout_seconds=$STOP_METHOD_TIMEOUT)..."
	else
	    echo "INFO: Method script will enforce a vm/stop_timeout of $STOP_TIMEOUT, SMF may have another opinion (stop/timeout_seconds=$STOP_METHOD_TIMEOUT)..."
	fi
    fi
    STOP_COUNT=0
    TS_STOPPING_STARTED="`getTimeStamp`" || \
	TS_STOPPING_STARTED=-1
    TS_DELTA=0

    VM_STATE="$( vm_state $1 )"

    ### Savestate action exits when the state is saved.
    ### "Button press" emulations exit after pressing the button.
    ### We want to sleep until the VM stops.
    [ x"$RES" = x0 ] && case "$STOP_METHOD" in
	savestate)
	    while [ "x$VM_STATE" != xsaved ]; do
		### Comparing timeout from counter to wallclock time reading -
		### executing these routines adds a good part of the second.
		sleep 1
		echodot

		VM_STATE="$( vm_state $1 )"
		case "x$VM_STATE" in
		    xaborted|xpoweroff)
			echo "ERROR: VM '$1' died during savestate!" >&2
			VM_STATE="saved"
			RES=126
			;;
		esac

		STOP_COUNT="$(($STOP_COUNT+1))" || STOP_COUNT=0
		if [ "$TS_STOPPING_STARTED" -gt 0 ]; then
			TS_NOW="`getTimeStamp`" && \
			    TS_DELTA=$(($TS_NOW - $TS_STOPPING_STARTED))
			[ $? != 0 ] && TS_DELTA=0
		fi
		if [ "$STOP_TIMEOUT" -gt 0 -a "$STOP_COUNT" -gt "$STOP_TIMEOUT" ] || \
		   [ "$STOP_TIMEOUT" -gt 0 -a "$TS_DELTA" -gt "$STOP_TIMEOUT" ]; then
		    echo "ERROR: VM '$1' stop timer expired ($STOP_COUNT cycles or $TS_DELTA sec > $STOP_TIMEOUT)" >&2
		    VM_STATE="saved"
		    RES=125
		fi
	    done
	    ;;
	poweroff|acpipowerbutton)
	    while [ "x$VM_STATE" != xpoweroff ]; do
		### Comparing timeout from counter to wallclock time reading -
		### executing these routines adds a good part of the second.
		sleep 1
		echodot

		VM_STATE="$( vm_state $1 )"
		case "x$VM_STATE" in
			xaborted)
			echo "ERROR: VM '$1' died during poweroff!" >&2
			VM_STATE="poweroff"
			RES=126
			;;
			xsaved)
			echo "ERROR: VM '$1' was saved during poweroff!" >&2
			VM_STATE="poweroff"
			RES=126
			;;
		esac

		if [ "$RES" = 0 ]; then
			STOP_COUNT="$(($STOP_COUNT+1))" || STOP_COUNT=0
			if [ "$TS_STOPPING_STARTED" -gt 0 ]; then
				TS_NOW="`getTimeStamp`" && \
				    TS_DELTA=$(($TS_NOW - $TS_STOPPING_STARTED))
				[ $? != 0 ] && TS_DELTA=0
			fi
			if [ "$STOP_TIMEOUT" -gt 0 -a "$STOP_COUNT" -gt "$STOP_TIMEOUT" ] || \
			   [ "$TS_DELTA" -gt 0 -a "$TS_DELTA" -gt "$STOP_TIMEOUT" ]; then
				echo "ERROR: VM '$1' stop timer expired ($STOP_COUNT cycles or $TS_DELTA sec > $STOP_TIMEOUT)" >&2
				VM_STATE="poweroff"
				RES=125
			fi
		fi

		### TODO
		# [ "$RES" = 0 -a "$STOP_METHOD_ENDTIME" != 0 ] && ....
	    done
	    ;;
	acpisleepbutton) ;;
	reset) ;;
    esac

    zfssnap "$1" "poststop-$STOP_METHOD-$RES" || {
    # Occasionally a restart attempt fails because "a session is still open"
    # Unscientific WORKAROUND: sleep a little for other VBox processes
    # to "release" the VM
    echo "INFO: sync and nap..."
    sync; sleeper 3
    }

    echo "INFO: VM '$1' state is now: '$( vm_state $1 )'"

    return $RES
}

kill_vm_proc() {
    ### Find running process(es) corresponding to VM "$1" and try to kill
    ### them in the OS if they exist.

    if [ x"$RUN_AS" != x ]; then
	RUN_USER_NAME="`GETPROPARG_QUIET=true get_run_as 2>/dev/null`"
    else
	RUN_USER_NAME=""
    fi

    _R=""
    [ x"$RUN_USER_NAME" != x ] && \
	_R=" for runtime user $RUN_USER_NAME"
    echo "INFO: `LANG=C TZ=UTC date`: asked to kill processes for VM '$1'${_R}, if any..."
    unset _R

    VM_PIDS="`ps -ef | egrep '(VirtualBox|VBoxHeadless).*--startvm *'"$1 " | grep -w "$RUN_USER_NAME" | awk '{print $2}'`"
    if [ -n "$VM_PIDS" ] ; then
	echo "INFO: `LANG=C TZ=UTC date`: going to kill processes for VM '$1' : $VM_PIDS"
	ps -ef | egrep '(VirtualBox|VBoxHeadless).*--startvm *'"$1 " | grep -w "$RUN_USER_NAME"

	RES_KILL=0
	for S in 15 2 3 1 9 9; do
	    N=0
	    for P in $VM_PIDS ; do
		[ -d "/proc/$P" ] && N=$(($N+1)) && \
		    { $RUN_AS kill -$S "$P" || RES_KILL=$?; }
	    done
	    [ $N = 0 ] && return 0 || sleep 3
	done
	return $RES_KILL
    else
	echo "INFO: `LANG=C TZ=UTC date`: no running processes for VM '$1' were found"
	ps -ef | grep "$1"
	return 0
    fi
}

reboot_vm() {
    ### reboot VM "$1" via (acpipoweroff-poweroff-reset-poweron)
    ### can use "$2" == "ifruns" to poweron the VM only if it was running

    VM_STATE="$( vm_state $1 )"
    INITIAL_VM_STATE="$VM_STATE"

    case "x$INITIAL_VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
	echo "INFO: `LANG=C TZ=UTC date`: Beginning to reboot VM '$1' (currently '$INITIAL_VM_STATE')..."
	if [ "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
	    echo "INFO: Using timeout override value: '$VBOXSVC_TIMEOUT_OVERRIDE'"
	else
	    echo "INFO: If 'vm/stop_timeout' is not set, this process will hang indefinitely (see timeouts below)!"
	fi

	_FORCE_STOP_METHOD=acpipowerbutton
	echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
	FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
	RES=$?

	if [ $RES != 0 ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: That failed ($RES)"
	    _FORCE_STOP_METHOD=poweroff
	    echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
	    FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
	    RES=$?
	fi

	if [ $RES != 0 ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: That failed ($RES)"
	    _FORCE_STOP_METHOD=reset
	    echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
	    FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
	    RES=$?
	fi
	echo "INFO: `LANG=C TZ=UTC date`: Done stopping (result=$RES)"

	if [ "$KILL_VM_PROCESS" = yes ]; then
	    kill_vm_proc "$1"
	fi

	zfssnap "$1" "reboot-poststop-$_FORCE_STOP_METHOD-$RES" || \
	    sleeper 5
	;;
    xunknown)
	echo "INFO: `LANG=C TZ=UTC date`: Beginning to reboot VM '$1' (currently '$INITIAL_VM_STATE' - stuck or otherwise; skipping graceful modes)..."
	if [ "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
	    echo "INFO: Using timeout override value: '$VBOXSVC_TIMEOUT_OVERRIDE'"
	else
	    echo "INFO: If 'vm/stop_timeout' is not set, this process will hang indefinitely (see timeouts below)!"
	fi

	_FORCE_STOP_METHOD=poweroff
	echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
	FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
	RES=$?

	if [ $RES != 0 ]; then
		echo "INFO: `LANG=C TZ=UTC date`: That failed ($RES)"
		_FORCE_STOP_METHOD=reset
		echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
		FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
		RES=$?
	fi
	echo "INFO: `LANG=C TZ=UTC date`: Done stopping (result=$RES)"

	if [ "$KILL_VM_PROCESS" = yes ]; then
	    kill_vm_proc "$1"
	fi

	zfssnap "$1" "reboot-poststop-$_FORCE_STOP_METHOD-$RES" || \
	    sleeper 5
	;;
    esac

    RET=-1
    if [ x"$2" = x"ifruns" ]; then
	case "x$INITIAL_VM_STATE" in
	xrunning|xstarting|xrestoring|xpaused|xunknown)
	    echo "INFO: `LANG=C TZ=UTC date`: Starting VM '$1' because it was in state '$INITIAL_VM_STATE'..."
	    start_vm "$1"
	    RET=$?
	    ;;
	x*) echo "INFO: `LANG=C TZ=UTC date`: VM '$1' was not running ($INITIAL_VM_STATE), not starting!" ;;
	esac
    else
	echo "INFO: `LANG=C TZ=UTC date`: Starting VM '$1'..."
	start_vm "$1"
	RET=$?
    fi
    echo "INFO: `LANG=C TZ=UTC date`: Done starting (result=$RET)"

    return $RET
}

poweroff_vm() {
    ### Part of reboot_vm's logic
    ### power off VM "$1" via (acpipoweroff-poweroff)

    VM_STATE="$( vm_state $1 )"
    INITIAL_VM_STATE="$VM_STATE"

    case "x$INITIAL_VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
	echo "INFO: `LANG=C TZ=UTC date`: Beginning to poweroff VM '$1' (currently '$INITIAL_VM_STATE')..."
	if [ "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
	    echo "INFO: Using timeout override value: '$VBOXSVC_TIMEOUT_OVERRIDE'"
	else
	    echo "INFO: If 'vm/stop_timeout' is not set, this process will hang indefinitely (see timeouts below)!"
	fi

	_FORCE_STOP_METHOD=acpipowerbutton
	echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
	FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
	RES=$?

	if [ $RES != 0 ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: That failed ($RES)"
	    _FORCE_STOP_METHOD=poweroff
	    echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
	    FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
	    RES=$?
	fi

	if [ $RES != 0 ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: That failed ($RES)."
	    if [ "$KILL_VM_PROCESS" != yes ]; then
		echo "	The VM process may need to be killed, consider the '-k' option."
	    fi
	fi
	echo "INFO: `LANG=C TZ=UTC date`: Done stopping (result=$RES)"

	if [ "$KILL_VM_PROCESS" = yes ]; then
	    kill_vm_proc "$1"
	fi

	zfssnap "$1" "poweroff-poststop-$_FORCE_STOP_METHOD-$RES" || \
	    sleeper 5
	;;
    xunknown)
	echo "INFO: `LANG=C TZ=UTC date`: Beginning to poweroff VM '$1' (currently '$INITIAL_VM_STATE' - stuck or otherwise; skipping graceful modes)..."
	if [ "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
	    echo "INFO: Using timeout override value: '$VBOXSVC_TIMEOUT_OVERRIDE'"
	else
	    echo "INFO: If 'vm/stop_timeout' is not set, this process will hang indefinitely (see timeouts below)!"
	fi

	_FORCE_STOP_METHOD=poweroff
	echo "INFO: `LANG=C TZ=UTC date`: Trying $_FORCE_STOP_METHOD..."
	FORCE_STOP_METHOD=$_FORCE_STOP_METHOD stop_vm "$1"
	RES=$?

	if [ $RES != 0 ]; then
		echo "INFO: `LANG=C TZ=UTC date`: That failed ($RES)."
		if [ "$KILL_VM_PROCESS" != yes ]; then
		    echo "	The VM process may need to be killed, consider the '-k' option."
		fi
	fi
	echo "INFO: `LANG=C TZ=UTC date`: Done stopping (result=$RES)"

	if [ "$KILL_VM_PROCESS" = yes ]; then
	    kill_vm_proc "$1"
	fi

	zfssnap "$1" "reboot-poststop-$_FORCE_STOP_METHOD-$RES" || \
	    sleeper 5
	;;
    esac
    return $RET
}

vm_state() {
    ### Get current state of VM "$1"
    $RUNAS /usr/bin/VBoxManage showvminfo "$1" --details --machinereadable | \
	grep VMState\= | tr -s '"' ' ' | cut -d " " -f2

    if [ $? -ne 0 ]; then
	echo "ERROR: Failed to get VMState for VM $1" >&2
	exit $SMF_EXIT_ERR_FATAL
    fi
}

ZFSSNAP_FLAG_OVERRIDE=""
zfssnap() {
    ### Try to create a snapshot of the VM-related datasets
    ### (will sleep a little and sync first).
    ###  $1	vm_name
    ###  $2	prestart|poststop
    ### Snapshot naming format:
    ###  dataset@{prefix}:{vm_name}:{prestart|poststop}:{vm_state}:{timestamp}
    ### Datasets are listed in SMF config and/or autodetected.
    ### NOTE: Removal of obsolete snapshots is the user's task (see for example
    ### zfs-auto-snap service for its removal of snapshots due to free space
    ### and/or snapshot age constraints).
    ### NOTE: Paths and dataset names should not contain spaces!

    if [   x"$ZFSSNAP_FLAG_OVERRIDE" = xtrue \
	-o x"$ZFSSNAP_FLAG_OVERRIDE" = xfalse ]; then
	ZFSSNAP_FLAG="$ZFSSNAP_FLAG_OVERRIDE"
    else
	ZFSSNAP_FLAG="$( GETPROPARG_QUIET=true; [ x"$DEBUG_SMF" = xtrue ] && GETPROPARG_QUIET=false; export GETPROPARG_QUIET; getproparg vm/zfssnap_flag )" || \
	    ZFSSNAP_FLAG=false
    fi

    if [ x"$ZFSSNAP_FLAG" != xtrue ]; then
	[ x"$DEBUG_SMF" = xtrue ] && echo "INFO: zfssnap_flag='$ZFSSNAP_FLAG' for VM '$1': '$2', doing nothing" >&2
	return 1
    fi
    ### Virtual Machine's state according to VirtualBox
    VM_STATE="$( vm_state $INSTANCE )"

    echo "INFO: Asked to create ZFS snapshots for VM '$1': '$2' ($VM_STATE)..."

    ZFSSNAP_PREFIX="$( GETPROPARG_QUIET=true; [ x"$DEBUG_SMF" = xtrue ] && GETPROPARG_QUIET=false; export GETPROPARG_QUIET; getproparg zfssnap_prefix )" || \
	ZFSSNAP_PREFIX=""
    [ x"$ZFSSNAP_PREFIX" = x ] && ZFSSNAP_PREFIX="vboxsvc-auto-snap"

    SNAPTAG="$ZFSSNAP_PREFIX:$1:$2:$VM_STATE:`TZ=UTC date -u "+%Y-%m-%dz%H:%M"`"

    ZFSSNAP_DSLIST="$( GETPROPARG_QUIET=true; [ x"$DEBUG_SMF" = xtrue ] && GETPROPARG_QUIET=false; export GETPROPARG_QUIET; getproparg zfssnap_dslist )" || \
	ZFSSNAP_DSLIST="auto"
    ZFSSNAP_DSLIST_APPEND="$( GETPROPARG_QUIET=true; [ x"$DEBUG_SMF" = xtrue ] && GETPROPARG_QUIET=false; export GETPROPARG_QUIET; getproparg zfssnap_dslist_append )" || \
	ZFSSNAP_DSLIST_APPEND=""

    if [ x"$ZFSSNAP_DSLIST" = xauto ]; then
	ZFSSNAP_DSLIST=""

	### TODO: Not certain about SCSI grepping, needs testing
	echo "INFO: Trying to detect VM-related ZFS datasets..."
	VM_FILES="$( $RUNAS /usr/bin/VBoxManage showvminfo "$1" \
		--details --machinereadable | \
	    egrep '^(hd.|VMStateFile|CfgFile|sataport.+|scsiport.*)="/' | \
	    cut -d '"' -f2 )"

	if [ $? -ne 0 ]; then
	    echo "ERROR: Failed to get list of component files for VM $1" >&2
	    exit $SMF_EXIT_ERR_FATAL
	fi

	### Solaris 'df' allows to pass it filenames and see their FS mounts
	if [ x"$VM_FILES" != x ]; then
	    [ x"$DEBUG_SMF" = xtrue ] && \
		echo "DEBUG: VM_FILES=$VM_FILES"

	    ### NOTE: Technically this can hang or timeout for NFS shares
	    ### Such condition would not let the VM work anyway, so special
	    ### tricks like time-limited running are not required here.
	    ZFSSNAP_DSLIST="`/bin/df -k $VM_FILES | awk '{print $NF}' | \
		grep '/' | sort | uniq | while read D; do \
		[ -d "$D/.zfs/snapshot" ] && echo "$D"; done`"

	    ### Try to parse the possible descriptor files used to mount raw
	    ### partitions and ZFS volumes as virtual HDDs. Also note that
	    ### non-root users need access rights for such files and volumes,
	    ### and a "zfs allow" delegation to take snapshots of the volume.
	    for D in $VM_FILES ; do
		case "`file "$D"`" in
		    "$D"*ascii\ text)
			V=""; VF=""
			[ "`head -1 "$D"`" = "# Disk DescriptorFile" ] && \
			    VF="`grep "/dev/zvol" "$D" | awk '{print $NF}' | sed 's,",,g'`" && \
			    V="`echo "$VF" | sed 's,^/dev/zvol/rdsk/,,' | sed 's,^/dev/zvol/dsk/,,'`"
			[ x"$V" != x ] && ZFSSNAP_DSLIST="$ZFSSNAP_DSLIST $V"
			;;
		esac
	    done

	    [ x"$DEBUG_SMF" = xtrue ] && \
		echo "DEBUG: ZFSSNAP_DSLIST=$ZFSSNAP_DSLIST"
        fi
    fi

    echo "INFO: Ensure all writes have ceased (sleep+sync+sleep)..."
    sleeper 3
    sync
    sleeper 2

    echo "INFO: Trying to snapshot VM-related ZFS datasets '@$SNAPTAG'..."
    for _DS in $ZFSSNAP_DSLIST $ZFSSNAP_DSLIST_APPEND; do echo "$_DS"; done | \
    sort | uniq | while read DS; do
	SNAP=yes
	case "$DS" in
	-)  ;;	### Skip requested explicitly
	/*) ### Assume it is a ZFS ZPL mountpoint
	    if [ x"$SNAP" = xyes -a ! -d "$DS" ]; then
		echo "ERROR: '$DS' is not a directory, skipping..."
		SNAP=no
	    fi

	    if [ x"$SNAP" = xyes -a ! -d "$DS/.zfs/snapshot" ]; then
		echo "ERROR: '$DS' is not a ZFS mountpoint, skipping..."
		SNAP=no
	    fi

	    if [ x"$SNAP" = xyes ]; then
		if [ x"$RUNAS" != x ]; then
		### Try as unprivileged user first, be nice ;)
		### Might also be the only way it works over NFS idmap-ing...
		    $RUNAS mkdir "$DS/.zfs/snapshot/$SNAPTAG" && SNAP=no
		fi
		[ x"$SNAP" = xyes ] && mkdir "$DS/.zfs/snapshot/$SNAPTAG" && SNAP=no
	    fi

	    if [ x"$SNAP" = xyes ]; then
		echo "ERROR: failed to make a snapshot dir '$DS/.zfs/snapshot/$SNAPTAG'!" >&2
	    else
		echo "INFO: created snapshot '$DS/.zfs/snapshot/$SNAPTAG'"
	    fi
	    ;;
	*)  ### Assume it is a ZFS dataset name
	    if [ x"$SNAP" = xyes ]; then
		if [ x"$RUNAS" != x ]; then
		### Try as unprivileged user first, be nice ;)
		### Might also be the only way it works over NFS idmap-ing...
		    $RUNAS zfs snapshot "$DS@$SNAPTAG" && SNAP=no
		fi
		[ x"$SNAP" = xyes ] && zfs snapshot "$DS@$SNAPTAG" && SNAP=no
	    fi

	    if [ x"$SNAP" = xyes ]; then
		echo "ERROR: failed to make snapshot '$DS@$SNAPTAG'!" >&2
	    else
		echo "INFO: created snapshot '$DS@$SNAPTAG'"
	    fi
	    ;;
	esac
    done
    return 0
}

dirlist() {
    ### List FS objects related to the VM - those grepped from VM info like
    ### zfssnap-auto, and those explicitly (optionally) listed in SMF setup.

    echo "Listing FS objects related to VM '$1':"

    ZFSSNAP_DSLIST="$( GETPROPARG_QUIET=true getproparg zfssnap_dslist )" || \
	ZFSSNAP_DSLIST="auto"
    ZFSSNAP_DSLIST_APPEND="$( GETPROPARG_QUIET=true getproparg zfssnap_dslist_append )" || \
	ZFSSNAP_DSLIST_APPEND=""

    VM_FILES="$( $RUNAS /usr/bin/VBoxManage showvminfo "$1" \
		--details --machinereadable | \
	    egrep '^(hd.|VMStateFile|CfgFile|sataport.+|scsiport.*)="/' | \
	    cut -d '"' -f2 )"

    ### Solaris 'df' allows to pass it filenames and see their FS mounts
    ZFSSNAP_DSLIST_AUTO=""
    if [ x"$VM_FILES" != x ]; then
	ZFSSNAP_DSLIST_AUTO="`/bin/df -k $VM_FILES | awk '{print $NF}' | \
		grep '/' | sort | uniq | while read D; do \
		[ -d "$D/.zfs/snapshot" ] && echo "$D"; done`"
    fi

    case "$ZFSSNAP_DSLIST" in
	-|"")	echo "SMF: vm/zfssnap_dslist = '$ZFSSNAP_DSLIST'"
		echo "	Explicitly disabled" ;;
	auto)	echo "SMF: vm/zfssnap_dslist = '$ZFSSNAP_DSLIST'"
		echo "	Use autodetected list (below)" ;;
	*)	echo "SMF: vm/zfssnap_dslist ="
		for D in $ZFSSNAP_DSLIST; do
		    echo "	$D"
		done ;;
    esac

    case "$ZFSSNAP_DSLIST_APPEND" in
	-|"")	echo "SMF: vm/zfssnap_dslist_append = '$ZFSSNAP_DSLIST_APPEND'"
		echo "	Explicitly disabled" ;;
	*)	echo "SMF: vm/zfssnap_dslist_append ="
		for D in $ZFSSNAP_DSLIST_APPEND; do
		    echo "	$D"
		done ;;
    esac

    case "$ZFSSNAP_DSLIST_AUTO" in
	"")	echo "AUTODETECT: No ZFS-backed VM datafiles were detected" ;;
	*)	echo "AUTODETECT: Following ZFS dataset(s) were detected backing VM datafiles:"
		for D in $ZFSSNAP_DSLIST_AUTO; do
		    echo "	$D"
		done ;;
    esac

    case "$VM_FILES" in
	"")	echo "AUTODETECT: Could not detect any VM datafiles at all!" ;;
	*)	echo "AUTODETECT: Following VM datafile paths were inspected:"
		for D in $VM_FILES; do
		    echo "	$D"
		    case "`file "$D"`" in
		    "$D"*ascii\ text)
			V=""; VF=""
			[ "`head -1 "$D"`" = "# Disk DescriptorFile" ] && \
			    VF="`grep "/dev/zvol" "$D" | awk '{print $NF}' | sed 's,",,g'`" && \
			    V="`echo "$VF" | sed 's,^/dev/zvol/rdsk/,,' | sed 's,^/dev/zvol/dsk/,,'`"
			[ x"$V" != x ] && echo "		backed by ZVOL '$V' ($VF)"
			;;
		    esac
		done ;;
    esac
}

ABORT_COUNTER=""
addAbortedCounter() {
    RESTART_ABORTED_VM_FAILURES_MAXCOUNT="$( getproparg vm/restart_aborted_vm_failures_maxcount )" || \
	RESTART_ABORTED_VM_FAILURES_MAXCOUNT=""
    RESTART_ABORTED_VM_FAILURES_TIMEFRAME="$( getproparg vm/restart_aborted_vm_failures_timeframe )" || \
	RESTART_ABORTED_VM_FAILURES_TIMEFRAME=""

    if [ x"$RESTART_ABORTED_VM_FAILURES_MAXCOUNT" != x -a \
	x"$RESTART_ABORTED_VM_FAILURES_TIMEFRAME" != x -a \
	"$RESTART_ABORTED_VM_FAILURES_MAXCOUNT" -gt 0 -a \
	"$RESTART_ABORTED_VM_FAILURES_TIMEFRAME" -gt 0 \
    ]; then
	TS_NOW="`getTimeStamp`" || \
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: aborted VM detected (state=$VM_STATE), but timestamping is not available. Total abortion count over eternity will be used."
	TS_CUTOFF="$(($TS_NOW-$RESTART_ABORTED_VM_FAILURES_TIMEFRAME))"

	if [ "`expr $RESTART_ABORTED_VM_FAILURES_MAXCOUNT \* \( 10 + $KICKER_FREQ \)`" -gt "$RESTART_ABORTED_VM_FAILURES_TIMEFRAME" ] ; then
		echo "WARNING : RESTART_ABORTED_VM_FAILURES_TIMEFRAME=${RESTART_ABORTED_VM_FAILURES_TIMEFRAME}sec is too short to track RESTART_ABORTED_VM_FAILURES_MAXCOUNT*(10+KICKER_FREQ)=${RESTART_ABORTED_VM_FAILURES_MAXCOUNT}sec*(10+$KICKER_FREQ) history (+overheads)"
	fi

	### Chop off old entries, add the new one
	ABORT_COUNTER="$( for TS in $ABORT_COUNTER; do [ "$TS" -ge "$TS_CUTOFF" ] && echo "$TS"; done; echo "$TS_NOW" )"
	NUM="`echo "$ABORT_COUNTER" | wc -l`"
	if [ "$NUM" -gt "$RESTART_ABORTED_VM_FAILURES_MAXCOUNT" ]; then
	    echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, too many times (num = $NUM, max = $RESTART_ABORTED_VM_FAILURES_MAXCOUNT) over the past $RESTART_ABORTED_VM_FAILURES_TIMEFRAME seconds (checking every $KICKER_FREQ+10 sec). Requesting maintenance mode! Last abortion counts:"
	    echo "---"
	    echo "$ABORT_COUNTER"
	    echo "---"
	    echo "$TS_NOW  == now"
	    echo "---"
	    return 1
	fi
	if [ "$NUM" -gt "1" ]; then
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE $NUM times (max = $RESTART_ABORTED_VM_FAILURES_MAXCOUNT) over the past $RESTART_ABORTED_VM_FAILURES_TIMEFRAME seconds (checking every $KICKER_FREQ+10 sec)..."
	fi
    else
	echo "KICKER-INFO: `LANG=C TZ=UTC date`: aborted VM detected (state=$VM_STATE), but counter-over-timeframe is not configured or timestamping is not available. Skipping abort-count checks."
    fi
    return 0
}

VMSVCCHECK_COUNTER=""
addVMSvcCheckCounter() {
    KICKER_VMSVCCHECK_FAILURES_MAXCOUNT="$( getproparg vm/kicker_vmsvccheck_failures_maxcount )" || \
	KICKER_VMSVCCHECK_FAILURES_MAXCOUNT=""
    KICKER_VMSVCCHECK_FAILURES_TIMEFRAME="$( getproparg vm/kicker_vmsvccheck_failures_timeframe )" || \
	KICKER_VMSVCCHECK_FAILURES_TIMEFRAME=""

    if [ x"$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" != x -a \
	x"$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" != x -a \
	"$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" -gt 0 -a \
	"$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" -gt 0 \
    ]; then
	TS_NOW="`getTimeStamp`" || \
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors, but timestamping is not available. Total failure count over eternity will be used."
	TS_CUTOFF="$(($TS_NOW-$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME))"

	if [ "`expr $KICKER_VMSVCCHECK_FAILURES_MAXCOUNT \* \( 10 + $KICKER_FREQ \)`" -gt "$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" ] ; then
		echo "WARNING : KICKER_VMSVCCHECK_FAILURES_TIMEFRAME=${KICKER_VMSVCCHECK_FAILURES_TIMEFRAME}sec is too short to track KICKER_VMSVCCHECK_FAILURES_MAXCOUNT*(10+KICKER_FREQ)=${KICKER_VMSVCCHECK_FAILURES_MAXCOUNT}sec*(10+$KICKER_FREQ) history (+overheads)"
	fi

	### Chop off old entries, add the new one
	VMSVCCHECK_COUNTER="$( for TS in $VMSVCCHECK_COUNTER; do [ "$TS" -ge "$TS_CUTOFF" ] && echo "$TS"; done; echo "$TS_NOW" )"
	NUM="`echo "$VMSVCCHECK_COUNTER" | wc -l`"
	if [ "$NUM" -gt "$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" ]; then
	    echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors too many times (num = $NUM, max tolerated = $KICKER_VMSVCCHECK_FAILURES_MAXCOUNT) over the past $KICKER_VMSVCCHECK_FAILURES_TIMEFRAME seconds (checking every $KICKER_FREQ+10 sec). Requesting maintenance mode! Last failure counts:"
	    echo "---"
	    echo "$VMSVCCHECK_COUNTER"
	    echo "---"
	    echo "$TS_NOW  == now"
	    echo "---"
	    return 1
	fi
	if [ "$NUM" -gt "1" ]; then
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors $NUM times (max = $KICKER_VMSVCCHECK_FAILURES_MAXCOUNT) over the past $KICKER_VMSVCCHECK_FAILURES_TIMEFRAME seconds (checking every $KICKER_FREQ+10 sec)..."
	fi
    else
	echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors, but counter-over-timeframe is not configured or timestamping is not available. Skipping failure-count checks."
    fi
    return 0
}

GOT_PAUSED=0
GOT_HALTED=0
GOT_SAVED=0
GOT_STUCK=0
kick() {
    ### What happens if VM stops but not because of SMF controls?
    ### This continuously running routine should define what happens!

    ### Mirrors start() logic, but with a twist
    ### on continuously monitoring the VM state

    ### Check service state in order to quickly abort on failure/shutdown
    SVC_STATE="$( svcs -H -o state $SMF_FMRI )"

    case x"$SVC_STATE" in
	xonline|'xoffline*')
	    ;;
	'xonline*') ### maybe svcadm refresh at bad timing
	    sleep 3
	    SVC_STATE="$( svcs -H -o state $SMF_FMRI )"
	    if [ x"$SVC_STATE" = 'xonline*' ]; then
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: service $SMF_FMRI is '$SVC_STATE' for 3 sec, breaking the kicker loop" >&2
		return 1
	    fi
	    ;;
	x*) ### For other states - abort kicker
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: service $SMF_FMRI is '$SVC_STATE', breaking the kicker loop" >&2
	    return 1
	    ;;
    esac

    ### Log progress...
    KICKER_DEBUG="$( GETPROPARG_QUIET=true getproparg vm/kicker_debug )" || KICKER_DEBUG=""

    ### Anti-self-DoS delay each cycle.
    ### NOTE this also affects "svcadm disable/restart" times
    ### because all of the service's processes must exit before
    ### it's complete. (hangs in 'online*' state until then)
    ### We have a PID file and a killer to remedy that in most cases.
    KICKER_FREQ="$( GETPROPARG_QUIET=true getproparg vm/kicker_freq )" || KICKER_FREQ="50"

    if [ x"$KICKER_NOSLEEP" != xtrue ]; then
	### TODO: Perhaps keep track of OS time to account for however long
	### it took to complete a previous KICKER loop (i.e. monitoring hook
	### execution time might get deductible)?
	[ x"$KICKER_DEBUG" = xtrue ] && echo "KICKER-INFO: Sleeping $KICKER_FREQ"
	sleeper "$KICKER_FREQ"
    fi

    ### Update state info
    SVC_STATE="$( svcs -H -o state $SMF_FMRI )"
    NEW_SVC_STATE="$SVC_STATE"
    case x"$SVC_STATE" in
	xonline) ;;
	'xoffline*')
	    ### 'offline*' = a start method is still at work; don't interfere
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: service $SMF_FMRI is '$SVC_STATE', skipping this cycle" >&2
	    return 0;;
	x*) ### For other states - abort kicker
	    ### 'online*' = a stop method is at work; don't interfere
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: service $SMF_FMRI is '$SVC_STATE', breaking the kicker loop" >&2
	    return 1
	    ;;
    esac

    KICKER_NOKICK_FILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_nokick_file_name)" || \
	KICKER_NOKICK_FILE_NAME=""
    [    x"$KICKER_NOKICK_FILE_NAME" = x'""' \
      -o x"$KICKER_NOKICK_FILE_NAME" = x"''" \
      -o x"$KICKER_NOKICK_FILE_NAME" = x \
    ] && KICKER_NOKICK_FILE_NAME="$KICKER_PIDFILE_NAME.nokick"

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
	echo "KICKER-INFO: `LANG=C TZ=UTC date`: located '$KICKER_NOKICK_FILE_NAME', skipping cycle" && \
	return 0

    ### Virtual Machine's current state according to VirtualBox
    VM_STATE="$( vm_state $INSTANCE )"

    ### Some flags control our reaction to failed VMs
    ### VMs which are not "running" may have been
    ### halted/saved/paused by user intentionally.
    ### We re-read these flags every cycle (if users
    ### don't forget "svcadm refresh VM_NAME"), so the
    ### user can set flags to "false" before acting on
    ### his VM manually, otherwise it might go back up
    ### (if "true") - which may be unexpected.

    ### We have an overriding option, use it if set...
    KICKER_RESTART="$( GETPROPARG_QUIET=true getproparg vm/kicker_restart )" || \
	KICKER_RESTART=""
    case x"$KICKER_RESTART" in
	x[Nn][Oo][Nn][Ee]|x[Nn][Oo]|x[Oo][Ff][Ff]|x[Ff][Aa][Ll][Ss][Ee])
	    ### Kicker-restart is enforced DISABLED
	    RESTART_ABORTED_VM=false
	    RESTART_PAUSED_VM=false
	    RESTART_HALTED_VM=false
	    RESTART_SAVED_VM=false
	    START_HALTED_VM=false
	    START_SAVED_VM=false
	    IGNORE_PAUSED_VM=true
	    ;;
	x[Aa][Ll][Ll]|x[Oo][Nn]|x[Tt][Rr][Uu][Ee])
	    ### Kicker-restart is enforced ENABLED
	    RESTART_ABORTED_VM=true
	    RESTART_PAUSED_VM=true
	    RESTART_HALTED_VM=true
	    RESTART_SAVED_VM=true
	    START_HALTED_VM=true
	    START_SAVED_VM=true
	    IGNORE_PAUSED_VM=true
	    ;;
	*)
	    ### Kicker-restart is configured in deeper detail or defaulted

	    ### Differentiate based on is_dualboot and is_interactive
	    IS_INTERACTIVE="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/is_interactive )" || \
		IS_INTERACTIVE=false
	    IS_DUALBOOT="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/is_dualboot )" || \
		IS_DUALBOOT=false
	    [ x"$IS_DUALBOOT" = xtrue ] && IS_INTERACTIVE=true

	    ### By hardcoded default of the script all REstarters are false
	    ### for non-interactive VMs, but starters may be true or false.
	    ### NOTE: it *may* be different in XML manifest of the SMF service
	    RESTART_ABORTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/restart_aborted_vm )" || \
	    RESTART_ABORTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_aborted_vm )" || \
	    RESTART_ABORTED_VM=""

	    if [ x"$RESTART_ABORTED_VM" = x ]; then
		if [ x"$IS_INTERACTIVE" != xtrue ]; then
		    RESTART_ABORTED_VM="$( getproparg vm/restart_aborted_vm )" || \
		    RESTART_ABORTED_VM="$( getproparg vm/start_aborted_vm )" || \
		    RESTART_ABORTED_VM="false"
		else
		    RESTART_ABORTED_VM=false
		fi
	    fi

	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		RESTART_PAUSED_VM="$( getproparg vm/restart_paused_vm )" || \
		RESTART_PAUSED_VM="$( getproparg vm/start_paused_vm )" || \
		RESTART_PAUSED_VM=false
	    else
		RESTART_PAUSED_VM="$( GETPROPARG_INHERIT=false getproparg vm/restart_paused_vm )" || \
		RESTART_PAUSED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_paused_vm )" || \
		RESTART_PAUSED_VM=false
	    fi

	    ### If the VM is properly "halted" or "saved", this was user's
	    ### explicit choice; don't revert to "start_*" option values.
	    ### However if the related "start_*" settings are "true", use
	    ### this setting to determine if the SMF service shouldn't stop.
	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		RESTART_HALTED_VM="$( getproparg vm/restart_halted_vm )" || \
		RESTART_HALTED_VM=false
	    else
		RESTART_HALTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/restart_halted_vm )" || \
		RESTART_HALTED_VM=false
	    fi

	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		RESTART_SAVED_VM="$( getproparg vm/restart_saved_vm )" || \
		RESTART_SAVED_VM=false
	    else
		RESTART_SAVED_VM="$( GETPROPARG_INHERIT=false getproparg vm/restart_saved_vm )" || \
		RESTART_SAVED_VM=false
	    fi

	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		RESTART_STUCK_VM="$( getproparg vm/restart_stuck_vm )" || \
		RESTART_STUCK_VM=false
	    else
		RESTART_STUCK_VM="$( GETPROPARG_INHERIT=false getproparg vm/restart_stuck_vm )" || \
		RESTART_STUCK_VM=false
	    fi

	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		START_HALTED_VM="$( getproparg vm/start_halted_vm )" || \
		START_HALTED_VM=true
	    else
		START_HALTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_halted_vm )" || \
		START_HALTED_VM=true
	    fi

	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		START_SAVED_VM="$( getproparg vm/start_saved_vm )" || \
		START_SAVED_VM=true
	    else
		START_SAVED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_saved_vm )" || \
		START_SAVED_VM=true
	    fi

	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		IGNORE_PAUSED_VM="$( getproparg vm/ignore_paused_vm )" || \
		IGNORE_PAUSED_VM=true
	    else
		IGNORE_PAUSED_VM="$( GETPROPARG_INHERIT=false getproparg vm/ignore_paused_vm )" || \
		IGNORE_PAUSED_VM=true
	    fi

	    if [ x"$IS_INTERACTIVE" != xtrue ]; then
		START_STUCK_VM="$( getproparg vm/start_stuck_vm )" || \
		START_STUCK_VM=false
	    else
		START_STUCK_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_stuck_vm )" || \
		START_STUCK_VM=false
	    fi
	    ;;
    esac

    ### Anti-spam counter, see below
    [ "x$VM_STATE" != "xpaused" ] && GOT_PAUSED=0
    [ "x$VM_STATE" != "xpoweroff" ] && GOT_HALTED=0
    [ "x$VM_STATE" != "xsaved" -a "x$VM_STATE" != "xsaving" ] && GOT_SAVED=0
    [ "x$VM_STATE" != "xunknown" ] && GOT_STUCK=0

    ### Counter for 'unknown' VM states to cause offline/maintenance
    ### (if max >= 0). If state is known, counter is kept at zero.
    UNKNOWN_STATE_COUNTER_PRV="$UNKNOWN_STATE_COUNTER"
    UNKNOWN_STATE_COUNTER=0

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring)
	[ x"$KICKER_DEBUG" = xtrue ] && \
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is already in state $VM_STATE."
	NEW_SVC_STATE="online"

	KICKER_VMSVCCHECK_ENABLED="$( getproparg vm/kicker_vmsvccheck_enabled)" || \
	    KICKER_VMSVCCHECK_ENABLED="false"
	if [ x"$KICKER_VMSVCCHECK_ENABLED" = xtrue -a "x$VM_STATE" = xrunning ]; then
	    KICKER_VMSVCCHECK_METHOD="$( getproparg vm/kicker_vmsvccheck_method)" || \
		KICKER_VMSVCCHECK_METHOD=""
	    if [ x"$KICKER_VMSVCCHECK_METHOD" != x -a -x "$KICKER_VMSVCCHECK_METHOD" ]; then
		KICKER_VMSVCCHECK_STARTDELAY="$( getproparg vm/kicker_vmsvccheck_startdelay)" || \
		    KICKER_VMSVCCHECK_STARTDELAY="300"

		OK=yes
		TS_NOW="`getTimeStamp`"
		if [ $? = 0 ]; then
		    if [  x"$TS_VM_STARTED" != x \
			-a "$TS_VM_STARTED" -gt 0 \
			-a "$TS_VM_STARTED" -le "$TS_NOW" \
		    ]; then
			if [ "$(($TS_NOW-$TS_VM_STARTED))" -lt "$KICKER_VMSVCCHECK_STARTDELAY" ]; then
			    [ x"$KICKER_DEBUG" = xtrue ] && \
				echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check hook is enabled, but delay time since VM start has not yet expired, skipping check"
			    OK=no
			fi
		    fi
		fi

		if [ x"$OK" = xyes ]; then
		    KICKER_VMSVCCHECK_METHOD_PARAMS="$( getproparg vm/kicker_vmsvccheck_method_params | sed 's,\\\\ , ,g' | sed 's,\\ , ,g')" || \
			KICKER_VMSVCCHECK_METHOD_PARAMS=""

		    "$KICKER_VMSVCCHECK_METHOD" $KICKER_VMSVCCHECK_METHOD_PARAMS
		    KICKER_VMSVCCHECK_RESULT_RAW=$?

		    ### TODO: Test more. This logic was implemented from theory
		    ### but not yet extensively checked in field practice

### Hook for an arbitrary method+params of checking that the VM provides
### its services (web, dbms, ping, etc). As far as vbox-svc is concerned,
### this external method is an executable program or script which should
### return an error code of:
###   0 for okay (clear counter),
###   1 for failure detected, increase counter, reboot VM on overflow
###   2 for instant reboot VM (acpipoweroff-poweroff-reset-poweron),
###   3 for instant cause SMF maintenance
### Override-values for exit codes can be defined for a VM's SMF instance.
### It is encouraged that the method uses some limitation of its execution
### time, as each loop cycle will have to wait for the check to complete.
### Note for COS&HT users: see /opt/COSas/bin/timerun.sh - COSas package
### Note: for reboots to work it is critical to set a vm/stop_timeout

		    KICKER_VMSVCCHECK_EXITCODE_OKAY="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/kicker_vmsvccheck_exitcode_okay )" || \
			KICKER_VMSVCCHECK_EXITCODE_OKAY="0"
		    KICKER_VMSVCCHECK_EXITCODE_FAILONCE="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/kicker_vmsvccheck_exitcode_failonce )" || \
			KICKER_VMSVCCHECK_EXITCODE_FAILONCE="1"
		    KICKER_VMSVCCHECK_EXITCODE_DOREBOOT="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/kicker_vmsvccheck_exitcode_doreboot )" || \
			KICKER_VMSVCCHECK_EXITCODE_DOREBOOT="2"
		    KICKER_VMSVCCHECK_EXITCODE_MAINTENANCE="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/kicker_vmsvccheck_exitcode_maintenance )" || \
			KICKER_VMSVCCHECK_EXITCODE_MAINTENANCE="3"

		    OK=no
		    KICKER_VMSVCCHECK_RESULT="$KICKER_VMSVCCHECK_RESULT_RAW"
		    [ x"$OK" = xno ] && for R in $KICKER_VMSVCCHECK_EXITCODE_OKAY; do
			[ x"$R" = x"$KICKER_VMSVCCHECK_RESULT_RAW" ] && \
				KICKER_VMSVCCHECK_RESULT="0" && OK=yes
		    done
		    [ x"$OK" = xno ] && for R in $KICKER_VMSVCCHECK_EXITCODE_FAILONCE; do
			[ x"$R" = x"$KICKER_VMSVCCHECK_RESULT_RAW" ] && \
				KICKER_VMSVCCHECK_RESULT="1" && OK=yes
		    done
		    [ x"$OK" = xno ] && for R in $KICKER_VMSVCCHECK_EXITCODE_DOREBOOT; do
			[ x"$R" = x"$KICKER_VMSVCCHECK_RESULT_RAW" ] && \
				KICKER_VMSVCCHECK_RESULT="2" && OK=yes
		    done
		    [ x"$OK" = xno ] && for R in $KICKER_VMSVCCHECK_EXITCODE_MAINTENANCE; do
			[ x"$R" = x"$KICKER_VMSVCCHECK_RESULT_RAW" ] && \
				KICKER_VMSVCCHECK_RESULT="3" && OK=yes
		    done

		    case "$KICKER_VMSVCCHECK_RESULT" in
			0) ### OK
			    [ x"$VMSVCCHECK_COUNTER" != x ] && \
				echo "KICKER-INFO: resetting error counter (list was $VMSVCCHECK_COUNTER)"
			    VMSVCCHECK_COUNTER=""
			    ;;
			2) ### Instant reboot
			    echo "KICKER-INFO: requesting VM reboot due to a fatal service-check failure..."
			    if reboot_vm "$INSTANCE"; then
				echo "KICKER-INFO: resetting error counters and startup-delay check"
				NEW_SVC_STATE=online
				VMSVCCHECK_COUNTER=""
			    else
				NEW_SVC_STATE=maintenance
			    fi
			    TS_VM_STARTED="`getTimeStamp`"
			    ;;
			3) ### cause SMF maintenance
			    echo "KICKER-INFO: requesting SMF maintenance due to critical service-check failures..."
			    NEW_SVC_STATE="maintenance"
			    ;;
			1|*) ### Single error
			    echo "KICKER-INFO: increasing error counter (list was ${VMSVCCHECK_COUNTER:-0})"
			    if ! addVMSvcCheckCounter; then
				echo "KICKER-INFO: requesting VM reboot due to repeated service-check failures..."
				if reboot_vm "$INSTANCE"; then
				    echo "KICKER-INFO: resetting error counters and startup-delay check"
				    NEW_SVC_STATE=online
				    TS_VM_STARTED="`getTimeStamp`"
				    VMSVCCHECK_COUNTER=""
				else
				    NEW_SVC_STATE=maintenance
				fi
			    fi
			    ;;
			esac
		fi
	    else
		[ x"$KICKER_DEBUG" = xtrue ] && echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE has KICKER_VMSVCCHECK_ENABLED but no valid method: '$KICKER_VMSVCCHECK_METHOD'"
	    fi
	fi
	;;
    xaborted)
	if [ "x$RESTART_ABORTED_VM" = "xtrue" ]; then
	    if addAbortedCounter; then
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, trying to start..."
		start_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance
		TS_VM_STARTED="`getTimeStamp`"
	    else
		echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, too many times (max = $RESTART_ABORTED_VM_FAILURES_MAXCOUNT) over the past $RESTART_ABORTED_VM_FAILURES_TIMEFRAME seconds (checking every $KICKER_FREQ+10 sec). Requesting maintenance mode!"
		NEW_SVC_STATE=maintenance
	    fi
	else
	    echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
	    echo "KICKER-INFO: to auto-start an aborted VM set its 'vm/restart_aborted_vm' SMF property to 'boolean: true'."
	    NEW_SVC_STATE="maintenance"
	fi
	;;
    xpaused)
	### A VM can also be paused if it is saving to disk
	if [ "x$IGNORE_PAUSED_VM" != "xtrue" ]; then
	    [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
		echo "KICKER-INFO: located '$KICKER_NOKICK_FILE_NAME', skipping cycle" && \
		return 0

	    if [ "x$RESTART_PAUSED_VM" = "xtrue" ]; then
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, trying to unpause..."
		resume_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance
		TS_VM_STARTED="`getTimeStamp`"
	    else
		echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
		echo "KICKER-INFO: to auto-unpause a VM set its 'vm/restart_paused_vm' SMF property to 'boolean: true'."
		NEW_SVC_STATE="offline"
	    fi
	else
	    ### If we asked to ignore the paused state, we might not want SPAM in logs ;)
	    GOT_PAUSED="$(($GOT_PAUSED+1))" || GOT_PAUSED=0
	    [ x"$KICKER_DEBUG" = xtrue -o x"$GOT_PAUSED" = x1 ] && \
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE. Ignoring per SMF service configuration."
	fi
	;;
    xpoweroff)
	if [ "x$RESTART_HALTED_VM" = "xtrue" ]; then
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, trying to start..."
	    start_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance
	    TS_VM_STARTED="`getTimeStamp`"
	else
	    if [ "x$START_HALTED_VM" = "xtrue" ]; then
		echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
		echo "KICKER-INFO: to auto-restart a halted VM set its 'vm/restart_halted_vm' SMF property to 'boolean: true'."
		NEW_SVC_STATE="offline"
	    else
		GOT_HALTED="$(($GOT_HALTED+1))" || GOT_HALTED=0
		[ x"$KICKER_DEBUG" = xtrue -o x"$GOT_HALTED" = x1 ] && \
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, but I won't start it nor fail myself, because its vm/start_halted_vm = boolean: false."
	    fi
	fi
	;;
    xsaved)
	[ -f "$KICKER_NOKICK_FILE_NAME" ] && echo "KICKER-INFO: located '$KICKER_NOKICK_FILE_NAME', skipping cycle" && return 0
	RESTART_SAVED_VM_ONCE_FILE_NAME="$( getproparg vm/kicker_restart_saved_vm_once_file_name )" || \
	RESTART_SAVED_VM_ONCE_FILE_NAME=""

	[ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x'""' -o \
	  x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"''" -o \
	  x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"true" ] && RESTART_SAVED_VM_ONCE_FILE_NAME=""
	[ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
	    RESTART_SAVED_VM_ONCE_FILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.restart_saved_once"
	[ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x ] && \
	    RESTART_SAVED_VM_ONCE_FILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.restart_saved_once"

	echo "RESTART_SAVED_VM_ONCE_FILE_NAME='$RESTART_SAVED_VM_ONCE_FILE_NAME'"
	if [ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" != xfalse ]; then
	    if [ -f "$RESTART_SAVED_VM_ONCE_FILE_NAME" ]; then
		echo "KICKER-INFO: Found a 'RESTART_SAVED_VM_ONCE_FILE_NAME'='$RESTART_SAVED_VM_ONCE_FILE_NAME' file,"
		echo "      enforcing a saved VM restart attempt this time."

		rm -f "$RESTART_SAVED_VM_ONCE_FILE_NAME"
		RESTART_SAVED_VM=true
	    fi
	fi

	if [ "x$RESTART_SAVED_VM" = "xtrue" ]; then
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got in state $VM_STATE, trying to unpause..."
	    start_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance
	    TS_VM_STARTED="`getTimeStamp`"
	else
	    if [ "x$START_SAVED_VM" = "xtrue" ]; then
	        echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
		echo "KICKER-INFO: to auto-unpause a saved VM set its 'vm/restart_saved_vm' SMF property to 'boolean: true'."
	        NEW_SVC_STATE="offline"
	    else
		GOT_SAVED="$(($GOT_SAVED+1))" || GOT_SAVED=0
		[ x"$KICKER_DEBUG" = xtrue -o x"$GOT_SAVED" = x1 ] && \
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, but I won't start it nor fail myself, because its vm/start_saved_vm = boolean: false."
	    fi
	fi
	;;
    xsaving)
	echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is now in state $VM_STATE, I can't start it. Maybe next cycle?"
	return 0
	;;
    xunknown)
	if [ "x$RESTART_STUCK_VM" = "xtrue" ]; then
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE (maybe stuck), trying to halt and start..."
	    poweroff_vm $INSTANCE && \
	    start_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance
	    TS_VM_STARTED="`getTimeStamp`"
	else
	    if [ "x$START_STUCK_VM" = "xtrue" ]; then
		echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE (maybe stuck), but I won't restart it."
		echo "KICKER-INFO: to auto-restart a stuck VM set its 'vm/restart_stuck_vm' SMF property to 'boolean: true'."
		NEW_SVC_STATE="offline"
	    else
		GOT_STUCK="$(($GOT_STUCK+1))" || GOT_STUCK=0
		[ x"$KICKER_DEBUG" = xtrue -o x"$GOT_STUCK" = x1 ] && \
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, but I won't start it nor fail myself, because its vm/start_stuck_vm = boolean: false."
	    fi
	fi
	;;
    "")
	echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in bogus state (empty string), I can't start it now. Has the host just booted?.. Hopefully next KICKER cycles would succeed."
	return 0
	;;
    *)
	### For good or bad, there is a VMState return value literal "unknown",
	### which means a stuck VM, GURU Meditation state, etc. - beside those
	### (future defined) states that we treat as unknown to the script.
	### Not that this changes much... Still, literal "unknown" state is
	### processed as "stuck" above, and here we process undefined ones.
	UNKNOWN_STATE_COUNTER="$(($UNKNOWN_STATE_COUNTER_PRV+1))" || UNKNOWN_STATE_COUNTER=1
	UNKNOWN_STATE_COUNTER_MAX="`getproparg vm/offline_unknown_state_maxcount`" || UNKNOWN_STATE_COUNTER_MAX=0
	if [ "$UNKNOWN_STATE_COUNTER_MAX" -ge 0 ]; then
	    echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is now in unknown state $VM_STATE, I can't start it."
	    if [ "$UNKNOWN_STATE_COUNTER" -gt "$UNKNOWN_STATE_COUNTER_MAX" ]; then
		echo "KICKER-ERROR: offlining SMF service (counter $UNKNOWN_STATE_COUNTER > max $UNKNOWN_STATE_COUNTER_MAX)."
		NEW_SVC_STATE="offline"
	    fi
	else
	    if [ x"$UNKNOWN_STATE_PRV" != x"$VM_STATE" ]; then
		UNKNOWN_STATE_COUNTER=1
	    fi
	    UNKNOWN_STATE_PRV="$VM_STATE"

	    if [ "$UNKNOWN_STATE_COUNTER" = 1 ]; then
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is now in unknown state $VM_STATE, I can't start it. Offlining SMF service is disabled. Reporting only once."
	    fi
	fi
	;;
    esac

    if [ "$UNKNOWN_STATE_COUNTER" = 0 ]; then
	UNKNOWN_STATE_PRV=""
    fi

    if [ x"$NEW_SVC_STATE" != x"$SVC_STATE" ]; then
	if [ x"$NEW_SVC_STATE" = xoffline -a \
	     x"$( GETPROPARG_QUIET=true getproparg vm/offline_is_maint )" = xtrue \
	]; then
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: configured to cause MAINTENANCE instead of OFFLINE."
	    NEW_SVC_STATE="maintenance"
	fi

### NOTE: an unprivileged user may not have the rights to use svcadm
### In this case the simple loop-break would cause maintenance and
### restart by SMF. We'll protect against that with a lock file to
### cause many repetitive restart failures (3 by default) and SMF
### maintenance mode will kick in as we want.
### See docs for proper privilege delegation via RBAC profiles, i.e.
### http://hub.opensolaris.org/bin/view/Community+Group+smf/faq  chapter 2.1
### or http://web.archive.org/web/20130318055639/http://hub.opensolaris.org/bin/view/Community+Group+smf/faq

	echo "KICKER-INFO: `LANG=C TZ=UTC date`: requesting SMF '$NEW_SVC_STATE' state (was '$SVC_STATE')."

	### By arbitrarily chosen default, we remain in current SMF status
	### (which is probably online). Maybe the VM will come back by user
	### activity in VirtualBox GUI or command-line interface?
	SVCADM_RET=-1
	SVCADM_OUT=""

	if [ x"$NEW_SVC_STATE" = xonline ]; then
	    ### Not sure if we'll really ever get to this point
	    SVCADM_OUT="`LANG=C svcadm clear "$SMF_FMRI" 2>&1; LANG=C svcadm enable -t "$SMF_FMRI" 2>&1`"
	    SVCADM_RET=$?
	fi

	if [ x"$NEW_SVC_STATE" = xmaintenance ]; then
	    SVCADM_OUT="`LANG=C svcadm mark -tI maintenance "$SMF_FMRI" 2>&1`"
	    SVCADM_RET=$?
	fi

	if [ x"$NEW_SVC_STATE" = xoffline ]; then
	    ### The VM was shut down and our flags specify that
	    ### it should not be restarted. 
	    SVCADM_OUT="`LANG=C svcadm disable -t "$SMF_FMRI" 2>&1`"
	    SVCADM_RET=$?
	fi

	if [ x"$SVCADM_RET" = "x-1" ]; then
	    echo "INFO: svcadm not called. Strange..."
	    return 0
	fi

	if echo "$SVCADM_OUT" | grep "Permission denied" >/dev/null; then
	    ### Expecting failure for non-root users...
	    echo "INFO: execution user '`id`' is not allowed to manipulate his SMF service."
	    echo "    See docs on SMF and RBAC delegation, i.e.:"
	    echo "    http://hub.opensolaris.org/bin/view/Community+Group+smf/faq  (chapter 2.1) or "
	    echo "    http://web.archive.org/web/20130318055639/http://hub.opensolaris.org/bin/view/Community+Group+smf/faq"
	    echo "INFO: trying to set KICKER blockfile. Enabled ?= '$KICKER_BLOCKFILE_ENABLED'"
	    setBlockFile
	    [ x"$SVCADM_RET" = x0 ] && SVCADM_RET=$SMF_EXIT_ERR_PERM
	else
	    if [ x"$SVCADM_RET" != x0 ]; then
		### Whatever the reason, we wanted maintenance anyway...
		if [ x"$NEW_SVC_STATE" = xmaintenance -o \
		    x"$NEW_SVC_STATE" = xoffline \
		]; then
		    echo "INFO: failed SMF manipulation to disable service."
		    echo "INFO: trying to set KICKER blockfile. Enabled ?= '$KICKER_BLOCKFILE_ENABLED'"
		    setBlockFile
		fi
	    fi
	fi

	if [ "$SVCADM_RET" -lt 0 ]; then
	    echo "INFO: internally detected svcadm error (return code $SVCADM_RET), output:"
	else
	    echo "INFO: svcadm return code ($SVCADM_RET), output:"
	fi
	echo "---"
	echo "$SVCADM_OUT"
	echo "---"
	return "$SVCADM_RET"
    fi

    return 0
}

start() {
    VM_STATE=$( vm_state $INSTANCE )
    ### NOTE: The default SMF manifest sets some of these values to "true";
    ### if we don't see these for any reason, consider them "false" and don't
    ### affect the running system with "broken" VMs - leave it to for admins
    ### to sort out...
    START_ABORTED_VM="$( getproparg vm/start_aborted_vm )" || START_ABORTED_VM=false
    START_PAUSED_VM="$( getproparg vm/start_paused_vm )" || START_PAUSED_VM=false
    ### ...However these values were implicitly true in earlier versions,
    ### and so they remain for backwards compatibility - properly halted and
    ### saved VMs can start (that's the point) unless explicitly disabled.
    START_HALTED_VM="$( getproparg vm/start_halted_vm )" || START_HALTED_VM=true
    START_SAVED_VM="$( getproparg vm/start_saved_vm )" || START_SAVED_VM=true
    ### VMs in literal state "unknown" are now considered "stuck", (re)start
    ### is by default disabled because the state is not clearly defined.
    START_STUCK_VM="$( getproparg vm/start_stuck_vm )" || START_STUCK_VM=false

#    zfssnap "$INSTANCE" "prestartSMF"

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring)
	echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is already in state $VM_STATE."
	true
	;;
    xaborted)
	if [ "x$START_ABORTED_VM" = "xtrue" ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE was in state $VM_STATE, trying to start..."
	    start_vm $INSTANCE
	else
	    echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
	    echo "INFO: to auto-start an aborted VM set its 'vm/start_aborted_vm' SMF property to 'boolean: true'."
	    false
	fi
	;;
    xpaused)
	if [ "x$START_PAUSED_VM" = "xtrue" ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE was in state $VM_STATE, trying to unpause..."
	    resume_vm $INSTANCE
	else
	    echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
	    echo "INFO: to auto-unpause an aborted VM set its 'vm/start_paused_vm' SMF property to 'boolean: true'."
	    false
	fi
	;;
    xpoweroff)
	if [ "x$START_HALTED_VM" = "xtrue" ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, trying to start..."
	    start_vm $INSTANCE
	else
	    echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
	    echo "INFO: to auto-start a halted/powered-off VM set its 'vm/start_halted_vm' SMF property to 'boolean: true'."
	    #false
	    true
	fi
	;;
    xsaved)
	if [ "x$START_SAVED_VM" = "xtrue" ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, trying to resume..."
	    start_vm $INSTANCE
	else
	    echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
	    echo "INFO: to auto-resume a saved VM set its 'vm/start_saved_vm' SMF property to 'boolean: true'."
	    #false
	    true
	fi
	;;
    xunknown)
	if [ "x$START_STUCK_VM" = "xtrue" ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE (maybe stuck), trying to poweroff and start..."
	    poweroff_vm $INSTANCE && \
		start_vm $INSTANCE
	else
	    echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE (maybe stuck), I can't start it."
	    echo "INFO: to auto-resume a stuck VM set its 'vm/start_stuck_vm' SMF property to 'boolean: true'."
	    #false
	    true
	fi
	;;
    "") echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in bogus state (empty string),  I can't start it now. Has the host just booted?.. Hopefully next KICKER cycles would succeed."
	true
	;;
    *)
	echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
	false
	;;
    esac
}

stop() {
    VM_STATE="$( vm_state $INSTANCE )"

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
	echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, trying to stop..."
	stop_vm $INSTANCE
	;;
    xunknown)
	echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE (maybe stuck), trying to poweroff..."
	poweroff_vm $INSTANCE
	;;
    *)
	echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I won't stop it any further."
	;;
    esac

#    zfssnap "$INSTANCE" "poststopSMF"
}

stopOldKicker() {
    if [ -s "$KICKER_PIDFILE_NAME" ]; then
	OLDPIDS="`cat "$KICKER_PIDFILE_NAME"`"

	echo "INFO: `LANG=C TZ=UTC date`: Removing old KICKER PID-file '$KICKER_PIDFILE_NAME'..."
	rm -f "$KICKER_PIDFILE_NAME"
	if [ $? != 0 ]; then
	    echo "ERROR: KICKER PID-file removal failed. Requesting maintenance mode! More data:"
	    ls -lad "$KICKER_PIDFILE_NAME"
	    ls -ladV "$KICKER_PIDFILE_NAME"
	    exit $SMF_EXIT_ERR_FATAL
	fi

	### TODO: "kill: Permission denied" check. Maintenance?
	[ x"$OLDPIDS" != x ] && echo "INFO: Trying to kill old KICKER loop (may fail if process already dead, worse if no perms). PID(s): $OLDPIDS and descendants..."
	for P in $OLDPIDS; do
	    pkill -P "$P"
	    kill "$P"
	done

    fi
}

removeBlockFile() {
    if [ x"$KICKER_BLOCKFILE_ENABLED" = xtrue -a \
	 x"$KICKER_BLOCKFILE_NAME" != x -a \
	-f "$KICKER_BLOCKFILE_NAME" \
    ]; then
	rm -f "$KICKER_BLOCKFILE_NAME"
	if [ $? != 0 ]; then
	    echo "ERROR: `LANG=C TZ=UTC date`: bogus file removal failed. Requesting maintenance mode! More data:"
	    ls -lad "$KICKER_BLOCKFILE_NAME"
	    ls -ladV "$KICKER_BLOCKFILE_NAME"
	    exit $SMF_EXIT_ERR_FATAL
	fi
    fi
}

setBlockFile() {
    if [ x"$KICKER_BLOCKFILE_ENABLED" = xtrue -a \
	 x"$KICKER_BLOCKFILE_NAME" != x \
    ]; then
	MY_ID="`getUID`"
	echo "INFO: `LANG=C TZ=UTC date`: creating KICKER block-file '$KICKER_BLOCKFILE_NAME' with tag '$MY_ID'..."

	[ -f "$KICKER_BLOCKFILE_NAME" ] && removeBlockFile
	[ -f "$KICKER_BLOCKFILE_NAME" ] && chown "$MY_ID" "$KICKER_BLOCKFILE_NAME"
	echo "$MY_ID" > "$KICKER_BLOCKFILE_NAME"
    fi
}

testBlockFile() {
    if [ x"$KICKER_BLOCKFILE_ENABLED" = xtrue -a \
	 x"$KICKER_BLOCKFILE_NAME" != x -a \
	-f "$KICKER_BLOCKFILE_NAME" \
    ]; then
	echo "INFO: KICKER block-file exists: '$KICKER_BLOCKFILE_NAME'."

	### Check if age doesn't exceed set maximum
	KICKER_BLOCKFILE_AGE="-1"
	if [ x"$getFileTimeStamp_CMD" = x ]; then
	    echo "ERROR: getFileTimeStamp method unavailable. Can't check KICKER block-file age."
	    echo "ERROR: Triggering SMF failure mode by setting zero block-file age."
	    echo "ERROR: Remove block-file manually to enable the VM's SMF service instance."
	    echo "INFO: Consider installing gdate or perl for better accuracy."
	else
	    TS_NOW="`getTimeStamp`" || TS_NOW=1
	    TS_FILE="`getFileTimeStamp "$KICKER_BLOCKFILE_NAME"`" || TS_FILE=0
	    KICKER_BLOCKFILE_AGE="$(($TS_NOW-$TS_FILE))" || KICKER_BLOCKFILE_AGE="0"
	    [ "$KICKER_BLOCKFILE_AGE" -lt 0 ] && echo "INFO: block-file age is negative ($KICKER_BLOCKFILE_AGE). Clock skew?"
	fi

	### Check if owners match (should contain UIDnumber)
	MY_ID="`getUID`"
	FILE_ID="`head -1 "$KICKER_BLOCKFILE_NAME"`"
	FILE_OWNER="`ls -nl "$KICKER_BLOCKFILE_NAME" | awk '{print $3 }'`"

	if [ x"$MY_ID" = x"$FILE_ID" -a x"$MY_ID" = x"$FILE_OWNER" ]; then
	    if [ "$KICKER_BLOCKFILE_AGE" -le "$KICKER_BLOCKFILE_MAXAGE" ]; then
		### Update the file for next SMF check...
		touch "$KICKER_BLOCKFILE_NAME"

		echo "INFO: `LANG=C TZ=UTC date`: KICKER block-file is valid (age=$KICKER_BLOCKFILE_AGE, maxage=$KICKER_BLOCKFILE_MAXAGE, tag='$MY_ID'), pushing for maintenance mode. See logs above, maybe they will explain - why."
		exit $SMF_EXIT_ERR_FATAL
	    else
		echo "INFO: `LANG=C TZ=UTC date`: KICKER block-file expired, removing (age=$KICKER_BLOCKFILE_AGE, maxage=$KICKER_BLOCKFILE_MAXAGE)"
	        removeBlockFile
	    fi
	else
	    echo "ERROR: `LANG=C TZ=UTC date`: bogus block file. Checked data:"
	    echo "    MY_ID       = $MY_ID"
	    echo "    FILE_ID     = $FILE_ID"
	    echo "    FILE_OWNER  = $FILE_OWNER"

	    echo "INFO: attempting to remove bogus KICKER block file."
	    removeBlockFile
	fi
    fi
    echo ""
    return 0
}

run_as() {
    ### TODO: Make a bunch of variants using sudo, pfexec and such - these may
    ### be easier to use for non-root launchers of root's VMs (not asking for
    ### a password dozens of times).
    RUNAS_USER="$1"
    shift

    echo "INFO: Running in context of '$RUNAS_USER'..." >&2

    ### Running as another user via 'su' may cause echoing of shell greetings
    ### we don't want them in property values, etc. so redirect stderr/stdout
    #    su - "$RUNAS_USER" -c "$*"
    ( su - "$RUNAS_USER" -c " ($*) 2>&4 1>&3" ) 3>&1 4>&2 1>/dev/null 2>/dev/null
    ### We know BASH is available (this script is running) and it is good for 
    ### subshelling, so use it - and explicitly disable profiles/greetings to
    ### speed things up:
    #( su - "$RUNAS_USER" -c "/usr/bin/bash --noprofile --norc -c ' ($*) 2>&4 1>&3' " ) 3>&1 4>&2 1>/dev/null 2>/dev/null
}

get_run_as() {
    RUN_USER="$( GETPROPARG_QUIET=false getproparg method_context/user )" || \
	RUN_USER="root"
    [ x"$RUN_USER" = x ] && RUN_USER="root"

    CURR_USER_ID="`getUID`"
    RUN_USER_ID="`getUID "$RUN_USER"`"
    if [ $? = 0 ]; then
	### No error getting an ID
	if [ x"$CURR_USER_ID" != x"$RUN_USER_ID" ]; then
	    [ x"$RUNAS" = x ] && \
		echo "INFO: The script runs in context of user '$CURR_USER_ID' (`getUNAME`) and work with VM needs to be done in context of '$RUN_USER_ID' ($RUN_USER)." >&2 && \
		[ x"$CURR_USER_ID" != x0 ] && \
			echo "      Password of the latter may be requested (maybe many times)." >&2
	    RUNAS="run_as $RUN_USER" && export RUNAS
	    echo "$RUN_USER_ID"
	fi
    else
	echo "ERROR: unknown user name from SMF property 'method_context/user'='$RUN_USER', skipping RUNAS and probably erring on VM state..." >&2
	echo "    Possible causes: invalid VM service set-up or ldap/nis/... user-catalog error" >&2
    fi
    echo "$CURR_USER_ID"
}

getState() {
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller

    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null
    VM_STATE=$( vm_state $INSTANCE )

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring)
	SVC_RET=0 ;;
    xpaused)
	SVC_RET=1 ;;
    xsaving)
	SVC_RET=2 ;;
    xsaved)
	SVC_RET=3 ;;
    xpoweroff)
	SVC_RET=10 ;;
    xaborted)
	SVC_RET=20 ;;
    "")
	# Bogus state, occasionally VBox 3.0.12 has no string to report
	# In GUI it maps to definite states, i.e. when VM snapshots are rolling
	SVC_RET=125;;
    *)
	SVC_RET=126;;
    esac

    echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE'."
    echo "INFO: Setting status: '$SVC_RET'"

    echo "INFO: SMF service status:"
    svcs -p "$SMF_FMRI"
    echo "   'svcs' RETCODE = '$?'"

    echo 'INFO: data from `ps` process listing: VirtualBox processes:'
    ps -ef | grep -v grep | egrep "(comment|startvm) $INSTANCE"

    echo 'INFO: data from `ps` process listing: similarly named processes, possibly related:'
    ps -efZ | grep -v grep | grep "$INSTANCE" | fgrep -v "$$"

    CALLER=getState test_VMSVCCHECK

    if [ x"$IS_INTERACTIVE" = xtrue ]; then
	echo "INFO: This VM is marked 'interactive' or 'dualboot', and as such it is not"
    	echo "started nor tracked by SMF. If there were failures, they may be expected."
    fi

    echo "INFO: Returning status code: '$SVC_RET'"

    return $SVC_RET
}

test_VMSVCCHECK() {
    ### For possible VM service availability tests, we use KICKER_VMSVCCHECK_*
    ### methods, if they are properly configured. Don't have to be enabled for
    ### the KICKER itself, though ;)
    KICKER_VMSVCCHECK_METHOD="$( GETPROPARG_QUIET=true getproparg vm/kicker_vmsvccheck_method)" || \
	KICKER_VMSVCCHECK_METHOD=""
    [ x"$KICKER_VMSVCCHECK_METHOD" != x -a ! -x "$KICKER_VMSVCCHECK_METHOD" ] && \
	KICKER_VMSVCCHECK_METHOD=""
    KICKER_VMSVCCHECK_METHOD_PARAMS="$( GETPROPARG_QUIET=true getproparg vm/kicker_vmsvccheck_method_params | sed 's,\\\\ , ,g' | sed 's,\\ , ,g')" || \
	KICKER_VMSVCCHECK_METHOD_PARAMS=""

    KICKER_VMSVCCHECK_RESULT=0
    if [ x"$KICKER_VMSVCCHECK_METHOD" != x ]; then
	echo "INFO: a KICKER_VMSVCCHECK_METHOD is configured for VM '$INSTANCE'. Executing test:"
	echo "      '$KICKER_VMSVCCHECK_METHOD' $KICKER_VMSVCCHECK_METHOD_PARAMS"

	time "$KICKER_VMSVCCHECK_METHOD" $KICKER_VMSVCCHECK_METHOD_PARAMS
	KICKER_VMSVCCHECK_RESULT=$?

	if [ x"$CALLER" = xgetState ]; then
	    echo    "INFO: KICKER_VMSVCCHECK_RESULT=$KICKER_VMSVCCHECK_RESULT (data not returned to caller of getState())."
	else
	    echo    "KICKER_VMSVCCHECK_RESULT=$KICKER_VMSVCCHECK_RESULT"
	fi

	echo -e "INFO: Standard return code interpretation for KICKER hooks: \c"
	case "$KICKER_VMSVCCHECK_RESULT" in
	    0) echo "OK" ;;
	    1) echo "Bump counter (delayed reboot of VM)" ;;
	    2) echo "Instantly reboot VM" ;;
	    3) echo "Instantly cause SMF maintenance" ;;
	    *) echo "UNDEFINED CODE" ;;
	esac
    else
	if [ x"$CALLER" != xgetState ]; then
	    echo "INFO: KICKER_VMSVCCHECK_METHOD is not defined or valid, test skipped."
	    ### No errors detected - no method; return 0
	fi
    fi

    return $KICKER_VMSVCCHECK_RESULT
}

######################################################################
if [ x"$DEBUG_SMF" = x ]; then
    DEBUG_SMF="$( GETPROPARG_QUIET=true getproparg vm/debug_smf )"
    [ $? != 0 ] && DEBUG_SMF=false
fi
[ x"$DEBUG_SMF" = xtrue ] && echo "INFO: Enabling SMF script debug..." && set -x

######################################################################
### This is kinda like macro - detect a method to get epoch-time in seconds.
### We prefer gdate as it's faster; perl may be more avaialble.
### Both "PERL time()" and "gdate +%s" are documented to return the number
### of seconds since the Epoch (1970-01-01 00:00:00 UTC on UNIX) and should
### not require TZ=UTC or "gdate -u" tweaks. They won't hurt either ;)

getFileTimeStamp_GDATE() {
	if [ x"$GDATE" != x -a -x "$GDATE" ]; then
		TZ=UTC $GDATE -u -r "$1" +%s
		return
	fi
	echo 0
	return 1
}

getFileTimeStamp_PERL() {
	_OUT=$(TZ=UTC perl -e 'use File::stat;print stat("'"$1"'")->mtime . "\n";')
	_RES=$?

	if [ x"$_OUT" != x -a "$_RES" = 0 ]; then
		echo "$_OUT"
	else
		echo 0
	fi
	return $_RES
}

getTimeStamp_CMD=""
getFileTimeStamp_CMD=""

getTimeStamp() {
	if [ x"$getTimeStamp_CMD" != x ]; then
		_TS="`eval $getTimeStamp_CMD`" && \
			echo "$_TS" && return 0
	fi
	echo 0
	return 1
}

getFileTimeStamp() {
	if [ x"$getFileTimeStamp_CMD" != x ]; then
		_TS="`eval $getFileTimeStamp_CMD "$1"`" && \
			echo "$_TS" && return 0
	fi
	echo 0
	return 1
}

### Now detect and select the timestamping method, if any
if perl -e ';' 2>/dev/null; then
    getTimeStamp_CMD="TZ=UTC perl -e 'print time() . \"\n\";'" && \
    getFileTimeStamp_CMD="getFileTimeStamp_PERL"

    if [ x"$DEBUG_SMF" = xtrue ]; then
	echo "DEBUG: Timestamp PERL: `eval $getTimeStamp_CMD`"
	echo "DEBUG: Filestamp PERL: `eval $getFileTimeStamp_CMD "$0"`"
    fi
fi

### GNU date binary is a bit faster than PERL; try to use it by default
GDATE_LIST="/opt/COSac/bin/gdate /opt/sfw/bin/gdate /usr/local/bin/date /usr/local/bin/gdate /usr/sfw/bin/gdate /usr/bin/gdate /usr/gnu/bin/date /opt/gnu/bin/date"

# GDATE=""
[ x"$GDATE" != x -a ! -x "$GDATE" ] && GDATE=""

[ x"$GDATE" = x ] && for F in $GDATE_LIST; do
    if [ -x "$F" ]; then
	GDATE="$F"
	break
    fi
done
[ x"$GDATE" != x -a ! -x "$GDATE" ] && GDATE=""
if [ x"$GDATE" = x ]; then
    gdate && GDATE="`which gdate | head -1`"
fi
[ x"$GDATE" != x -a ! -x "$GDATE" ] && GDATE=""

if [ x"$GDATE" != x ]; then
    getTimeStamp_CMD="TZ=UTC $GDATE -u +%s"
    getFileTimeStamp_CMD="getFileTimeStamp_GDATE"
    if [ x"$DEBUG_SMF" = xtrue ]; then
	echo "DEBUG: Timestamp GDATE: `eval $getTimeStamp_CMD`"
	echo "DEBUG: Filestamp GDATE: `eval $getFileTimeStamp_CMD "$0"`"
    fi
fi

if [ x"$getTimeStamp_CMD" != x ]; then
    if [ "`eval $getTimeStamp_CMD`" -gt 0 ]; then
	true
    else
	### Invalid numbers, or negative values
	echo "ERROR: Could not detect a proper getTimeStamp_CMD() method!" >&2
	getTimeStamp_CMD=""
	getFileTimeStamp_CMD=""
    fi
else
    echo "ERROR: Could not detect a proper getTimeStamp_CMD() method!" >&2
fi

### Detect the socat client
if [ x"$SOCAT" = x -o ! -x "$SOCAT" ]; then
    SOCAT="`which socat 2>/dev/null`" || SOCAT=""
    case x"$SOCAT" in
	x/*)	;; # OK
	*)	SOCAT="" ;;
    esac
fi

TS_SCRIPT_STARTED="`getTimeStamp`"
echo "INFO: `LANG=C TZ=UTC date`: Script start timestamp = '$TS_SCRIPT_STARTED'"

############################################################################
### Actual body of work

GETPROPARG_QUIET=true get_run_as >/dev/null # 2>/dev/null

[ x"$VBOXSVC_TIMEOUT_OVERRIDE" = x ] && VBOXSVC_TIMEOUT_OVERRIDE=-1

### Check for transient/child/contract(default) mode...
#duration=""
#if /bin/svcprop -q -c -p startd/duration $SMF_FMRI 2>/dev/null ; then
#    duration="`/bin/svcprop -c -p startd/duration $SMF_FMRI`"
#fi

### Not all users may have write permissions to /var/run -
### so by default we use /tmp as it also clears on reboot
### TODO: Maybe write to VM's directory (esp. NFS) in case of shared storage
### on VM farms - to block simultaneous startup of VMs on different hosts, etc?
KICKER_PIDFILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_pidfile_name)" || \
    KICKER_PIDFILE_NAME=""
[ x"$KICKER_PIDFILE_NAME" = x'""' -o x"$KICKER_PIDFILE_NAME" = x"''" ] && \
    KICKER_PIDFILE_NAME=""
[ x"$KICKER_PIDFILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
    KICKER_PIDFILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.pid"
[ x"$KICKER_PIDFILE_NAME" = x ] && \
    KICKER_PIDFILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.pid"

KICKER_NOKICK_FILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_nokick_file_name)" || \
    KICKER_NOKICK_FILE_NAME=""
[    x"$KICKER_NOKICK_FILE_NAME" = x'""' \
  -o x"$KICKER_NOKICK_FILE_NAME" = x"''" \
  -o x"$KICKER_NOKICK_FILE_NAME" = x \
] && KICKER_NOKICK_FILE_NAME="$KICKER_PIDFILE_NAME.nokick"

KICKER_BLOCKFILE_ENABLED="$( GETPROPARG_QUIET=true getproparg vm/kicker_blockfile_enabled)" || \
    KICKER_BLOCKFILE_ENABLED=""
KICKER_BLOCKFILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_blockfile_name)" || \
    KICKER_BLOCKFILE_NAME=""
KICKER_BLOCKFILE_MAXAGE="$( GETPROPARG_QUIET=true getproparg vm/kicker_blockfile_maxage)" || \
    KICKER_BLOCKFILE_MAXAGE=""
[ x"$KICKER_BLOCKFILE_ENABLED" = x ] && KICKER_BLOCKFILE_ENABLED="true"
[ x"$KICKER_BLOCKFILE_NAME" = x'""' -o x"$KICKER_BLOCKFILE_NAME" = x"''" ] && \
    KICKER_BLOCKFILE_NAME=""
[ x"$KICKER_BLOCKFILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
    KICKER_BLOCKFILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.block"
[ x"$KICKER_BLOCKFILE_NAME" = x ] && \
    KICKER_BLOCKFILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.block"
[ x"$KICKER_BLOCKFILE_MAXAGE" = x ] && KICKER_BLOCKFILE_MAXAGE="60"

### Differentiate based on is_dualboot and is_interactive
IS_INTERACTIVE="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/is_interactive )" || \
    IS_INTERACTIVE=false
IS_DUALBOOT="$( GETPROPARG_INHERIT=false GETPROPARG_QUIET=true getproparg vm/is_dualboot )" || \
    IS_DUALBOOT=false
[ x"$IS_DUALBOOT" = xtrue ] && IS_INTERACTIVE=true

#################################################################
### Process requested command-line actions and/or SMF methods ###
#################################################################

SVC_RET=-1
case "$SCRIPT_METHOD" in
start-force|start)
    stopOldKicker
    testBlockFile

    VM_STATE="$( vm_state "$INSTANCE" )"
    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
	### The VM is already active, and in most cases we want to snatch
	### it to become a headless process under the SMF umbrella now.
	### For an interactive VM we won't kidnap its running process to
	### headless SMF, though.
	if [ "x$IS_INTERACTIVE" != "xtrue" ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE',"
	    echo "      trying to save VM state before starting SMF service..."
	    FORCE_STOP_METHOD=savestate stop_vm "$INSTANCE"
	fi
	;;
    xunknown)
	### The VM may be in GURU meditation state
	### VMs in literal state "unknown" are now considered "stuck", (re)start
	### is by default disabled because the state is not clearly defined.
	START_STUCK_VM="$( getproparg vm/start_stuck_vm )" || START_STUCK_VM=false

	if [ x"$START_STUCK_VM" = xtrue ]; then
	    echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE' (maybe stuck),"
	    echo "      trying to halt it ungracefully before starting SMF service..."
	    poweroff_vm "$INSTANCE"
	    VM_STATE="$( vm_state "$INSTANCE" )"
	else
	    echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE' (maybe stuck),"
	    echo "      and automatic (re)start is not enabled; the service script will probably fail..."
	fi
	;;
    esac

    DO_START=true
    if [ "x$IS_INTERACTIVE" = "xtrue" -a x"$1" = xstart ]; then
	DO_START=false
	echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE',"
	echo "	and its vm/is_interactive = true or vm/is_dualboot = true."

	case "x$VM_STATE" in
		xrunning|xstarting|xrestoring|xsaving)
			echo "	We won't save its state and restart as an SMF process."
			;;
		xpaused)
			START_PAUSED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_paused_vm )" || \
			START_PAUSED_VM=false
			[ x"$START_PAUSED_VM" = xtrue ] && DO_START=true || \
			echo "	We were not explicitly asked to start from such VM state."
			;;
		xaborted)
			START_ABORTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_aborted_vm )" || \
			START_ABORTED_VM=false
			[ x"$START_ABORTED_VM" = xtrue ] && DO_START=true || \
			echo "	We were not explicitly asked to start from such VM state."
			;;
		xpoweroff)
			START_HALTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_halted_vm )" || \
			START_HALTED_VM=false
			[ x"$START_HALTED_VM" = xtrue ] && DO_START=true || \
			echo "	We were not explicitly asked to start from such VM state."
			;;
		xsaved)
			START_SAVED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_saved_vm )" || \
			START_SAVED_VM=false
			[ x"$START_SAVED_VM" = xtrue ] && DO_START=true || \
			echo "	We were not explicitly asked to start from such VM state."
			;;
		"")
			echo "INFO: `LANG=C TZ=UTC date`: interactive VM $INSTANCE is in bogus state (empty string), I can't start it now."
			;;
		*)
			### We tried what we could with "unknown" (stuck) VM 
			### state above... if that failed - oh well...
			echo "INFO: `LANG=C TZ=UTC date`: interactive VM $INSTANCE is in unknown state ($VM_STATE), I can't start it now."
			;;
	esac
    fi

    ### For an interactive VM we don't autostart it with SMF startup
    ### unless requested at the instance level.
    if [ "x$DO_START" = "xtrue" ]; then
	echo "INFO: `LANG=C TZ=UTC date`: trying to start VM '$INSTANCE'..."
	start
	SVC_RET=$?
    else
	echo "	SMF will be there to properly stop the VM upon OS shutdown."
	SVC_RET=0
    fi

    if [ "$SVC_RET" -ne 0 ]; then
	echo "ERROR: `LANG=C TZ=UTC date`: VM '$INSTANCE' failed($SVC_RET) to do '$1'."
	exit $SMF_EXIT_ERR_FATAL
    fi

    ### For possible VM service availability tests, we use KICKER_VMSVCCHECK_*
    ### methods, if they are properly configured. Don't have to be enabled for
    ### the KICKER itself, though ;)
    KICKER_VMSVCCHECK_ENABLED="$( getproparg vm/kicker_vmsvccheck_enabled)" || \
	KICKER_VMSVCCHECK_ENABLED="false"
    KICKER_VMSVCCHECK_METHOD="$( getproparg vm/kicker_vmsvccheck_method)" || \
	KICKER_VMSVCCHECK_METHOD=""
    [ x"$KICKER_VMSVCCHECK_METHOD" != x -a ! -x "$KICKER_VMSVCCHECK_METHOD" ] && \
	KICKER_VMSVCCHECK_METHOD=""
    KICKER_VMSVCCHECK_METHOD_PARAMS="$( getproparg vm/kicker_vmsvccheck_method_params | sed 's,\\\\ , ,g' | sed 's,\\ , ,g')" || \
	KICKER_VMSVCCHECK_METHOD_PARAMS=""

    TS_VM_STARTED="`getTimeStamp`"
    ( ### KICKER loop
	sleeper 20
	echo "INFO: `LANG=C TZ=UTC date`: Starting KICKER monitoring of VM state."
	echo "INFO: First KICKER run may report unset SMF service parameters"
	echo "      where we had to apply defaults; further runs shouldn't."

	KICKER_NOSLEEP=true kick || exit

	### Just to inform the user if the variable is set...
	RESTART_SAVED_VM_ONCE_FILE_NAME="$( getproparg vm/kicker_restart_saved_vm_once_file_name )" || \
		RESTART_SAVED_VM_ONCE_FILE_NAME=""

	GETPROPARG_QUIET=true
	export GETPROPARG_QUIET
	KICKER_FREQ="$( GETPROPARG_QUIET=true getproparg vm/kicker_freq )" || KICKER_FREQ="50"
	echo "INFO: `LANG=C TZ=UTC date`: Starting KICKER endless loop for VM '$INSTANCE'; it will sleep 10+$KICKER_FREQ seconds between cycles."

	if [ x"$KICKER_VMSVCCHECK_ENABLED" = xtrue \
	  -a x"$KICKER_VMSVCCHECK_METHOD" != x \
	  -a -x "$KICKER_VMSVCCHECK_METHOD" \
	  ]; then
		echo "INFO: KICKER will also test services provided by the VM with '$KICKER_VMSVCCHECK_METHOD' '$KICKER_VMSVCCHECK_METHOD_PARAMS' (adding to the cycle length however long these checks take)."
set -x
		KICKER_VMSVCCHECK_FAILURES_MAXCOUNT="$( getproparg vm/kicker_vmsvccheck_failures_maxcount )" || \
			KICKER_VMSVCCHECK_FAILURES_MAXCOUNT=""
		KICKER_VMSVCCHECK_FAILURES_TIMEFRAME="$( getproparg vm/kicker_vmsvccheck_failures_timeframe )" || \
			KICKER_VMSVCCHECK_FAILURES_TIMEFRAME=""

		if [ x"$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" != x -a \
		    x"$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" != x -a \
		    "$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" -gt 0 -a \
		    "$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" -gt 0 \
		]; then
			if [ "`expr $KICKER_VMSVCCHECK_FAILURES_MAXCOUNT \* \( 10 + $KICKER_FREQ \)`" -gt "$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" ] ; then
				echo "WARNING : KICKER_VMSVCCHECK_FAILURES_TIMEFRAME=${KICKER_VMSVCCHECK_FAILURES_TIMEFRAME}sec is too short to track KICKER_VMSVCCHECK_FAILURES_MAXCOUNT*(10+KICKER_FREQ)=${KICKER_VMSVCCHECK_FAILURES_MAXCOUNT}sec*(10+$KICKER_FREQ) history (+overheads)"
			fi
		fi
set +x
	else
		echo "INFO: KICKER is not currently configured to test services provided by the VM (see vm/kicker_vmsvccheck_* properties)."
	fi

	### Here we enforce additional sleep, beside one defined by SMF property
	while kick; do sleeper 10; done ) &
    echo $! > "$KICKER_PIDFILE_NAME"

    ### Here we begin the start method exit delay, if configured by user
    ### The delay may be based on plain timeouts and/or on results of kicker's
    ### monitoring VM service-check hook tests if those are configured.
    START_WAIT_POLICY="$( GETPROPARG_QUIET=true getproparg vm/start_wait_policy)" || \
	START_WAIT_POLICY="nodelay"
    START_METHOD_TIMEOUT="$( GETPROPARG_QUIET=true getproparg start/timeout_seconds)" || \
	START_METHOD_TIMEOUT="0"
    START_METHOD_ENDTIME=0
    if [ "$TS_SCRIPT_STARTED" -gt 0 -a "$START_METHOD_TIMEOUT" -gt 5 ]; then
	### Here we arbitrarily give 5 seconds for errors and other failsafes
	### so that the VM is not aborted by SMF preliminarily.
	START_METHOD_ENDTIME="$(($TS_SCRIPT_STARTED + $START_METHOD_TIMEOUT - 5))"
    fi

    [ "$START_METHOD_ENDTIME" != 0 ] && case "$START_WAIT_POLICY" in
	timeout|delay|wait)
		START_WAIT_POLICY=timeout ;;
	hook_strict|vmsvccheck_strict)
		START_WAIT_POLICY=hook_strict
		[ x"$KICKER_VMSVCCHECK_METHOD" = x ] && \
			echo "START_WAIT-INFO: vm/start_wait_policy=$START_WAIT_POLICY was requested for VM '$INSTANCE', but no valid vm/kicker_vmsvccheck_method was provided. Falling back to plain start/timeout_seconds-5 delay." && \
			START_WAIT_POLICY=timeout
		;;
	hook|hook_lax|vmsvccheck|on|true)
		START_WAIT_POLICY=hook_lax
		[ x"$KICKER_VMSVCCHECK_METHOD" = x ] && \
			echo "START_WAIT-INFO: vm/start_wait_policy=$START_WAIT_POLICY was requested for VM '$INSTANCE', but no valid vm/kicker_vmsvccheck_method was provided. Falling back to plain start/timeout_seconds-5 delay." && \
			START_WAIT_POLICY=timeout
		;;
	nodelay|off|none|false|nowait)
		START_WAIT_POLICY=nodelay ;;
	default|-|""|*)
		START_WAIT_POLICY=nodelay ;;
    esac

    WAIT=nodelay
    if [ x"$START_WAIT_POLICY" != xnodelay -a x"$START_METHOD_ENDTIME" != x -a "$START_METHOD_ENDTIME" -gt 0 ]; then
	WAIT=yes
	TS_NOW="`getTimeStamp`"
	TO_SLEEP="$(($START_METHOD_ENDTIME-$TS_NOW))"
	case "$START_WAIT_POLICY" in
		timeout)
			echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: START_WAIT_POLICY=$START_WAIT_POLICY: the start method will now delay exit by $TO_SLEEP seconds." ;;
		hook_strict)
			echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: START_WAIT_POLICY=$START_WAIT_POLICY: the start method will now delay exit by up to $TO_SLEEP seconds and require the KICKER_VMSVCCHECK_METHOD='$KICKER_VMSVCCHECK_METHOD $KICKER_VMSVCCHECK_METHOD_PARAMS' to succeed; fails otherwise." ;;
		hook_lax)
			echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: START_WAIT_POLICY=$START_WAIT_POLICY: the start method will now delay exit by up to $TO_SLEEP seconds and hope for KICKER_VMSVCCHECK_METHOD='$KICKER_VMSVCCHECK_METHOD $KICKER_VMSVCCHECK_METHOD_PARAMS' to succeed (not required)." ;;
	esac
    fi

    KICKER_VMSVCCHECK_RESULT="NA"
    while [ "$WAIT" = yes ]; do
	TS_NOW="`getTimeStamp`"
	[ "$START_METHOD_ENDTIME" -le "$TS_NOW" ] && WAIT=expired
	[ "$WAIT" = yes ] && case "$START_WAIT_POLICY" in
		timeout)
			sleep 1 ;;
		hook*)
			### TODO: Hook execution can take longer than the SMF
			### timeout we are aware of. Devise a way to interrupt
			### the svc-check for hook_lax (sleeping self-killer?)
			### so that our guarantee of exiting 0 on hook_lax holds!
			"$KICKER_VMSVCCHECK_METHOD" $KICKER_VMSVCCHECK_METHOD_PARAMS
			KICKER_VMSVCCHECK_RESULT=$?
			if [ "$KICKER_VMSVCCHECK_RESULT" = 0 ]; then
				WAIT=hook_ok
			else
				sleep 1
			fi
			;;
		nodelay|*) ### Just in case - abort loop
			echo "START_WAIT-WARN: erratic START_WAIT_POLICY=$START_WAIT_POLICY, aborting delay loop."
			WAIT=nodelay ;;
	esac
    done

    case "$WAIT" in
	hook_ok)		echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' provides its services now! Quitting OK!" ;;
	expired) case "$START_WAIT_POLICY" in
		timeout)	echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' delay timer expired! Quitting OK!" ;;
		hook_lax)	echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' delay timer expired! Last hook check status: $KICKER_VMSVCCHECK_RESULT. Quitting OK!" ;;
		hook_strict)	if [ "$KICKER_VMSVCCHECK_RESULT" = 0 ]; then
					echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' delay timer expired! Last hook check status: $KICKER_VMSVCCHECK_RESULT. Quitting OK!"
				else
					echo "START_WAIT-INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' delay timer expired! Last hook check status: $KICKER_VMSVCCHECK_RESULT. FAILING VM, falling into SMF-maintenance! (Overriding stop timeout to 120sec)"
					VBOXSVC_TIMEOUT_OVERRIDE=120 stop &
					exit $SMF_EXIT_ERR_FATAL
				fi ;;
		esac ;;
    esac
    ;;
stop)
    ### TODO: Detect that the script is actually called by SMF and only
    ### use STOP_METHOD_ENDTIME in that case.
    STOP_METHOD_TIMEOUT="$( GETPROPARG_QUIET=true getproparg stop/timeout_seconds)" || \
	STOP_METHOD_TIMEOUT="0"
    STOP_METHOD_ENDTIME=0
    if [ "$TS_SCRIPT_STARTED" -gt 0 -a "$STOP_METHOD_TIMEOUT" -gt 5 ]; then
	### Here we arbitrarily give 5 seconds for errors and other failsafes
	### so that the VM is not aborted by SMF preliminarily.
	STOP_METHOD_ENDTIME="$(($TS_SCRIPT_STARTED + $STOP_METHOD_TIMEOUT - 5))"
    fi

    stopOldKicker
    stop
    SVC_RET=$?
    ;;
save|savestate|save-state)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    if [ x"$SMF_FMRI" = x -o x"$INSTANCE" = x ]; then
	echo "ERROR: requires valid SMF_FMRI of the VM instance!" >&2
	exit 1
    fi

    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    VM_STATE="$( vm_state "$INSTANCE" )"
    echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE'"
    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
	$RUNAS touch "$KICKER_NOKICK_FILE_NAME"

	echo "INFO: trying to savestate VM '$INSTANCE' if it is running..."
	echo "INFO: (failure due to already stopped VM is okay here)"
	FORCE_STOP_METHOD=savestate stop_vm "$INSTANCE"
	SVC_RET=$?
	echo "INFO: done stopping ($SVC_RET)"
	echo ""

	zfssnap "$INSTANCE" "manual-vmsave"
	;;
    *) ### Already stopped somehow - noop
	SVC_RET=0
	;;
    esac
    ;;
zfssnap)
    shift
    SNAP_COMMENT="$@" || SNAP_COMMENT=""
    [ x"$SNAP_COMMENT" = x ] && SNAP_COMMENT="manual-zfssnap"
    ZFSSNAP_FLAG_OVERRIDE=true zfssnap "$INSTANCE" "$SNAP_COMMENT"
    SVC_RET=$?
    ;;
dirlist)
    dirlist "$INSTANCE"
    SVC_RET=$?
    ;;
startgui|start-gui)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    if [ x"$SMF_FMRI" = x -o x"$INSTANCE" = x ]; then
	echo "ERROR: requires valid SMF_FMRI of the VM instance!" >&2
	exit 1
    fi

    if [ x"$DISPLAY" = x ]; then
	echo "ERROR: GUI start requires a valid DISPLAY variable!" >&2
	exit 2
    fi

    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    STARTGUI_RUNMODE=bg
    ### TODO: This fixes the stop_method at the one set in SMF properties
    ### (for this VM's SMF instance only) when the VM was started... is it ok?
    STARTGUI_FG_VMSTOP="$( GETPROPARG_INHERIT=false getproparg vm/stop_method)" || \
	STARTGUI_FG_VMSTOP=""
    [ x"$STARTGUI_FG_VMSTOP" = x ] && if [ "x$IS_INTERACTIVE" = "xtrue" ]; then
    	STARTGUI_FG_VMSTOP="poweroff-graceful"
    else
    	STARTGUI_FG_VMSTOP="savestate"
    fi

    shift
    while [ $# -gt 0 ]; do
	case "$1" in
	    -fg) STARTGUI_RUNMODE=fg ;;
	    -bg) STARTGUI_RUNMODE=bg ;;
	    --*) ### Some value may be predefined by caller's env
	    	STARTGUI_VBOX_PARAMS="$STARTGUI_VBOX_PARAMS $1" ;;
	    -stop_method|-stop_method=*)
	    	SM="`echo "$1" | sed 's/^\-stop_method=*//'`"
	    	[ $? != 0 -o x"$SM" = x ] && SM="$2"
	    	case "$SM" in
	    		acpipowerbutton|savestate|acpisleepbutton|poweroff|reset|poweroff-graceful)
	    		STARTGUI_FG_VMSTOP="$SM"; shift ;;
	    		*) echo "ERROR: Unknown startgui stop_method requested: '$SM', skipping this parameter."
	    		sleep 3;;
	    	esac
	    	;;
	    -t) VBOXSVC_TIMEOUT_OVERRIDE="$2"
	    	if [ x"$VBOXSVC_TIMEOUT_OVERRIDE" != x \
		    -a "$VBOXSVC_TIMEOUT_OVERRIDE" -gt 0 ]; then
		    [ x"$DEBUG_SMF" = xtrue ] && echo "INFO: Overriding poweroff timeout: '$VBOXSVC_TIMEOUT_OVERRIDE'" >&2
	    	else
		    echo "WARN: Invalid timeout value '$VBOXSVC_TIMEOUT_OVERRIDE' ignored" >&2
		    VBOXSVC_TIMEOUT_OVERRIDE=-1
	    	fi
	    	shift ;;
	    *) echo "ERROR: Unknown parameter to startgui method: '$1', skipped."
	    sleep 3;;
	esac
	shift
    done

    $RUNAS touch "$KICKER_NOKICK_FILE_NAME"

    echo "INFO: trying to stop (savestate) VM '$INSTANCE' just in case it is running..."
    echo "INFO: failure due to already stopped VM is okay here"
    FORCE_STOP_METHOD=savestate stop_vm "$INSTANCE"
    echo "INFO: done stopping ($?)"
    echo ""

    zfssnap "$INSTANCE" "prestartGUI"

    echo "INFO: trying to start VM '$INSTANCE' in GUI mode (DISPLAY='$DISPLAY', RUNAS='$RUNAS')..."
    _TRAP_OFF="true; "
    if [ x"$STARTGUI_RUNMODE" = xfg ]; then
	_TRAP_SIG="$( getproparg vm/startgui_fg_trap_signals)" || \
		_TRAP_SIG=""
	_TRAP_SIG="${_TRAP_SIG:-SIGHUP SIGINT SIGQUIT SIGTERM SIGABRT}"
	_TRAP_OFF=""
	for S in 0 $_TRAP_SIG; do
		_TRAP_OFF="$_TRAP_OFF trap '' $S;"
	done
    fi

    if [ x"$RUNAS" != x ]; then
	xhost +localhost
	eval $_TRAP_OFF
	( $RUNAS $_TRAP_OFF DISPLAY="$DISPLAY" exec /opt/VirtualBox/VirtualBox --startvm "$INSTANCE" --comment "$INSTANCE" $STARTGUI_VBOX_PARAMS ) &
	SVC_RET="$?"
    else
	eval $_TRAP_OFF
	/opt/VirtualBox/VirtualBox --startvm "$INSTANCE" --comment "$INSTANCE" $STARTGUI_VBOX_PARAMS &
	SVC_RET="$?"
    fi
    STARTGUI_PID=$!
    echo "INFO: `LANG=C TZ=UTC date`: started VirtualBox process: PID=$STARTGUI_PID, RET=$SVC_RET."

    if [ x"$STARTGUI_RUNMODE" = xfg ]; then
	echo "INFO: running in foreground mode: setting trap for exit signals..."

	startgui_trap() {
		echo "INFO: `LANG=C TZ=UTC date`: got signal '$1', stopping VM '$INSTANCE' with method '$STARTGUI_FG_VMSTOP'."
		FORCE_STOP_METHOD=$STARTGUI_FG_VMSTOP stop_vm "$INSTANCE"
		echo "INFO: `LANG=C TZ=UTC date`: done (result=$?)"
		trap "" 0
		exit
	}

	for S in 0 $_TRAP_SIG; do
	    trap "startgui_trap $S" "$S"
	done
    fi

    ### A small sleep seems necessary - sometimes request for VM status hangs
    ### if done too soon after VM startup
    sleep 3
    zfssnap "$INSTANCE" "poststartGUI"

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
	$RUNAS rm -f "$KICKER_NOKICK_FILE_NAME"

    if [ x"$SVC_RET" = x0 ]; then
	### Running as another user via 'su' may cause echoing of shell greetings
	### we don't want them in property values, so run this as current user
	RESTART_SAVED_VM_ONCE_FILE_NAME="$( getproparg vm/kicker_restart_saved_vm_once_file_name )" || \
		RESTART_SAVED_VM_ONCE_FILE_NAME=""

	[   x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x'""' -o \
	    x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"''" -o \
	    x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"true" ] && \
		RESTART_SAVED_VM_ONCE_FILE_NAME=""
	[ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
		RESTART_SAVED_VM_ONCE_FILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.restart_saved_once"
	[ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x ] && \
		RESTART_SAVED_VM_ONCE_FILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.restart_saved_once"

	if [ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" != xfalse ]; then
#	  if [ ! -f "$RESTART_SAVED_VM_ONCE_FILE_NAME" ]; then
	    echo "INFO: trying to leave a RESTART_SAVED_VM_ONCE_FILE_NAME file ($RESTART_SAVED_VM_ONCE_FILE_NAME)..."
	    $RUNAS touch "$RESTART_SAVED_VM_ONCE_FILE_NAME"
#	  fi
	fi

	echo ""
	echo "INFO: Current state of SMF service for this VM:"
	svcs -p $SMF_FMRI
	ps -ef | grep -w $STARTGUI_PID | grep -v grep
	echo "INFO: Relevant properties of SMF service for this VM regarding (re)starts:"
	svcprop $SMF_FMRI | egrep '^vm/(stop_method|.*start_.*_vm|kicker_freq) ' | sort

	echo ""
	echo "INFO: You can now work with the VM's GUI console. When finished, please"
	echo "select 'Save State' in the Close menu (HOSTKEY+Q) so SMF will pick up the"
	echo "VM (if the service is enabled and set up to restart halted/savedstate VMs)."
    else
	echo "ERROR: VM '$INSTANCE' startup error detected. Return code: '$SVC_RET'"
    fi

    if [ x"$STARTGUI_RUNMODE" = xfg ]; then
	echo "INFO: `LANG=C TZ=UTC date`: Running in foreground mode. Upon the end or termination of this script instance (PID=$$) the VM (PID=$STARTGUI_PID) will be stopped with '${STARTGUI_FG_VMSTOP:-default}'"
	[ x"$RUNAS_USER" != x ] && \
		echo "INFO: UID changes were required, so VM PID may be wrong. Here's process tree:" && \
		ptree $STARTGUI_PID
	wait $STARTGUI_PID
	SVC_RET=$?
	echo "INFO: `LANG=C TZ=UTC date`: VM process exited by itself (result=$SVC_RET)"
    fi
    ;;
getstate|state|status)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    getState
    SVC_RET=$?
    exit $SVC_RET
    ;;
vmsvccheck|hook)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    test_VMSVCCHECK
    SVC_RET=$?
    exit $SVC_RET
    ;;
poweroff|poweroff-graceful)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    $RUNAS touch "$KICKER_NOKICK_FILE_NAME"

    [ "$2" = "-k" ] && KILL_VM_PROCESS=yes && shift
    poweroff_vm "$INSTANCE"
    SVC_RET=$?

#    stopOldKicker

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
	$RUNAS rm -f "$KICKER_NOKICK_FILE_NAME"

    exit $SVC_RET
    ;;
reboot)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    $RUNAS touch "$KICKER_NOKICK_FILE_NAME"

    [ "$2" = "-k" ] && KILL_VM_PROCESS=yes && shift
    reboot_vm "$INSTANCE" $2
    SVC_RET=$?

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
	$RUNAS rm -f "$KICKER_NOKICK_FILE_NAME"

    exit $SVC_RET
    ;;
reset)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    $RUNAS touch "$KICKER_NOKICK_FILE_NAME"

    FORCE_STOP_METHOD=reset stop_vm "$INSTANCE"
    SVC_RET=$?

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && $RUNAS rm -f "$KICKER_NOKICK_FILE_NAME"

    exit $SVC_RET
    ;;

sercon|sercon-loop|sercon-once)
    SVC_RET=0
    ### Other clients are also possible, such as some implementations of
    ### netcat (with pipe support), but socat-1.7.0.0 is what we know to work
    if [ x"$SOCAT" = x -o ! -x "$SOCAT" ]; then
	echo "ERROR: The socat client is absent from PATH or invalid (not executable)!" >&2
	[ x"$SOCAT" != x ] && echo "	'$SOCAT'" >&2
	SVC_RET=3
    else
	### Detect the pipe file - from command-line explicitly, or from serial
	### port number and VM config, or default by VM config (IFF there's
	### only one "server" UART port).

	SLEEP=5
	shift
	while [ $# -gt 0 ]; do
	    case "$1" in
		-f)	SERCON_PIPE="$2"; shift ;;
		-u)	SERCON_UART="$2"; shift ;;
		*)	if [ "$1" -gt 0 ]; then
			    SLEEP="$1"
			else
			    echo "Unknown parameter: $1, skipped"
			fi
			;;
	    esac
	    shift
	done

	if [ x"$SERCON_PIPE" = x ]; then
	    echo "INFO: Trying to detect VM serial port settings..."
	    VM_UART="$( $RUNAS /usr/bin/VBoxManage showvminfo "$INSTANCE" \
		--details --machinereadable | \
		egrep '^uartmode.*=' | sed 's/^uartmode//' )"
	    if [ $? -ne 0 ]; then
		echo "ERROR: Failed to get VM serial port settings!" >&2
		exit $SMF_EXIT_ERR_FATAL
	    fi

	    if [ x"$SERCON_UART" = x ]; then
		VM_UART_HITS="`echo "$VM_UART" | egrep '="server,'`"
	    else
		### Other sercon types may include connections onto physical
		### serial ports of the host, files pre-created outside VBox.
		### These can be specified manually by host FS object name
		### or by VM UART port number.
		VM_UART_HITS="`echo "$VM_UART" | egrep '^'"$SERCON_UART="`"
	    fi

	    if [ "`echo "$VM_UART_HITS" | wc -l | sed 's, ,,g'`" != 1 ]; then
		echo "ERROR: Did not find exactly one UART port in VM config!" >&2
		echo "$VM_UART_HITS"
		SVC_RET=4
	    else
		SERCON_PIPE="`echo "$VM_UART_HITS" | sed 's/^.*=[^,]*,\(\/.*\)$/\1/' | sed 's,",,g'`"
	    fi
	fi

	if [ x"$SERCON_PIPE" != x ]; then
	    echo "INFO:	Will try to '$SOCAT' to sercon VM '$INSTANCE' using"
	    echo "	pipe file '$SERCON_PIPE'"
	    echo "NOTE:	Use '$0 -vm $INSTANCE sercon-break'"
	    echo "	in another terminal to kill this client"

	    DO_EXIT=0
	    case "$SCRIPT_METHOD" in
		sercon-once)
		    echo "INFO: Doing only one connection attempt, no looping..."
		    DO_EXIT=-2
		    ;;
	    esac
	    trap "stty sane; stty erase '^H'; DO_EXIT=127" 0 1 2 3 15

	    while true; do
		SKIP=no
		PSVM="`ps -ef | grep "$INSTANCE" | grep -v grep | grep Virtu`" 
		if [ $? != 0 -o x"$PSVM" = x ]; then
		    echo "`date`: The VM '$INSTANCE' seems to be not running now; skipping cycle" 
		    SKIP=yes
		else
		    echo "$PSVM" 
		fi

		if [ x"$SKIP" = xno -a ! -S "$SERCON_PIPE" ]; then
		    echo "`date`: The VM '$INSTANCE' serial console pipe file '$SERCON_PIPE' is not active now; skipping cycle"
		    SKIP=yes
		fi

		if [ x"$SKIP" = xno ]; then
		    echo "`date`: Starting SOCAT on pipe '$SERCON_PIPE'..." 
		    "$SOCAT" unix-connect:"$SERCON_PIPE" stdio,raw,echo=0,icanon=0
		    RES=$?
		    case "$RES" in
			0) ;; ### Good result, don't raise exit-flag
			1) ;; ### 2013/05/05 22:47:24 socat[4105] E connect(3, AF=1 "/tmp/sercon-illumos-gui.pipe", 30): Connection refused
			*) DO_EXIT=$RES ;;
		    esac
		    stty sane
		    stty erase '^H'
		fi

		echo "" 
		if [ "$DO_EXIT" != 0 ]; then
		    if [ "$DO_EXIT" = -2 ]; then
			DO_EXIT=0
			echo "`date`: SOCAT exited, quitting OK after one loop"
		    else
			echo "`date`: SOCAT aborted ($DO_EXIT), quitting"
		    fi
		    exit $DO_EXIT
		fi
		echo "`date`: RETRYING SOCAT after a short sleep..." 
		sleeper $SLEEP
	    done
	fi
    fi

    ;;

sercon-break|sercon-abort|sercon-stop)
    SVC_RET=0
    OLD_PID="`ps -ef | grep "$INSTANCE" | grep "$SOCAT" | grep -v grep | awk '{print $2}'`" 
    if [ x"$OLD_PID" != x ]; then
	echo "Killing old SOCAT: $OLD_PID" >&2
	ps -ef | grep -v grep | grep -w "$OLD_PID"
	kill $OLD_PID
	SVC_RET=$?
    fi
    ;;

help|--help|-help|-h|'-?'|'/?')
    printHelp
    echo "INFO: `LANG=C TZ=UTC date`: printed help. Did not try to change state of VM '$INSTANCE'"
    SVC_RET=0
    ;;
*)
    echo "ERROR: Unknown parameter(s) passed: '$0 $@'"
    printHelp
    SVC_RET=$SMF_EXIT_ERR_CONFIG
    ;;
esac

if [ "$SVC_RET" -ne 0 ]; then
    echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE failed($SVC_RET) to do '$SCRIPT_METHOD'."
    exit $SMF_EXIT_ERR_FATAL
fi

exit $SMF_EXIT_OK
