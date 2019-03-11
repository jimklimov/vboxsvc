HISTORY AND AUTHORS

* Copyright (C) 2012-2019 by Jim Klimov, JSC COS&HT
* Thanks to Edward Ned Harvey for idea and constructive discussion while we
  authored our different solutions to the same problem

INTRODUCTION

zfs-zvolrights is a script that can be installed as an SMF service to retain
the POSIX/ACL access rights on device nodes owned by non-roots (notably the
user-owned ZFS volumes used as local or iSCSI "raw devices" for VM disk images)
between storage host reboots, as a workaround of Solaris/illumos deficiency in
this regard.

See more here:
* http://openindiana.org/pipermail/openindiana-discuss/2012-October/010238.html
* http://www.mail-archive.com/zfs-discuss@opensolaris.org/msg50229.html
* https://www.illumos.org/issues/3283
   ZFS RFE: correctly remember device node ownership and ACLs for ZVOLs
* https://www.illumos.org/issues/3284
   devfs BUG: ACLs on device node can become applied to wrong devices;
   UID/GID not retained

The problem is that ZFS by itself currently "forgets" between reboots (or
even "live" pool export-import cycles) the POSIX and ACL metadata associated
with the ZVOL device nodes. This can cause problems ranging from inconvenience
to security breaches when such devices are used for unprivileged users' VMs.

I made a generic script which can save POSIX and ACL info from devfs into
"user-defined" attributes of ZVOLs and extract and apply those values to
ZVOLs on demand. This script can register itself as an SMF service, and
apply such values from zfs to devfs at service startup, and save from
devfs to zfs at the service shutdown. Since the information is saved onto
the pool, it is possible to properly apply it after storage failover to
another similarly configured head in clustered setups. This likely requires
user accounts to be provisioned with the same IDs (i.e. from common LDAP).

I guess this can be integrated into my main vbox.sh script to initiate
such activities during ordinary VM startup/shutdown, but haven't yet
explored or completed this variant (all the needed pieces should be
there already). Perhaps I need to make such integration before next
"official" release of vboxsvc.

========================================================================
WARNING: PROVIDED AS IS FOR TESTING, MAY BREAK THINGS IN PRODUCTION

This is rather a proof-of-concept so far (i.e. the script should be
sure to run after zpool imports/before zpool exports), but brave souls
can feel free to try it out and comment. Presence of the service didn't
cause any noticeable troubles on my test boxen over the past couple of
weeks.

BEWARE, YOU'VE BEEN WARNED
========================================================================

More detail on the problem from my emails at that time:

> A VirtualBox VM can use delegated zvols as "dsk" or "rdsk" devices
> on the host, just like it can use delegated raw disks or partitions,
> likely iSCSI volumes and other block devices. According to Edward,
> block devices yield better performance than VDI files for VM disks.
> A VM can be executed by an unprivileged user, and thus the device
> node needs to be RW accessible to that non-root user (whom and why
> to trust - that's the admin's problem, OS should not limit that).
>
> So, the problem detected with ZVOLs (and I expect it can have a
> wider range on other devices) is that the ownership of the device
> node for a zvol is forgotten upon reboot or other pool reimport.
> That is, the node used by a VM should be chown'ed upon every VM
> startup. That's inconvenient, so to say.
>
> I played more with this and found that I can also set ACLs with
> /bin/chmod on device nodes, and that is even remembered across
> reboots, however with /dev/zvol/*dsk/pool/vol being a dynamically
> assigned symlink like /devices/pseudo/zfs at 0:4(,raw) there is a
> problem: the symlink and device node is created when I look at
> it (i.e. upon first "ls" or another access to the /dev/zvol/...
> object), and the device node occupies the first available number.
> The /devices filesystem seems to remember ACL entries (but not
> ownerships) across reboots only in conjunction with its object
> names, so upon each reboot (reimport) of the pool, the same
> device node name can get assigned to different zvols.
>
> This is not only "useless" in terms of stably providing access
> to certain devices for certain users, but also harmful as after
> a reboot an unexpected user (among those earlier trusted) can
> gain access to incorrect devices (and might even enforce that
> somehow, by being first to access the device at the correct
> moment) and cause DoS or intentional illicit access to other
> users' data.

HTH,
//Jim Klimov

