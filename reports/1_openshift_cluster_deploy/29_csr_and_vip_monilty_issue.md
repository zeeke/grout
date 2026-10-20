Yes, it's stuck, and it won't finish without manual action. ClusterVersion has shown Available=False for 141 minutes. Only master-1 and master-2 joined the cluster. master-0, worker-0 and worker-1 are booted from disk with kubelet running, but none of their client CSRs are being approved.

Evidence

1. Only 2 of 5 nodes are registered, and ClusterVersion is failing:
$ oc get clusterversion
version   False   True   141m   Unable to apply 4.22.3: an unknown error has occurred: MultipleErrors
$ oc get nodes
master-1   Ready   control-plane,master   128m
master-2   Ready   control-plane,master   128m
2. The missing nodes are asking to join, but nobody approves them:
$ oc get csr | grep Pending   → decoded subjects:
      4 CN=system:node:master-0
      4 CN=system:node:worker-0
      4 CN=system:node:worker-1
   The master-0 kubelet confirms it: No valid client certificate is found ... User "system:anonymous" cannot get resource "leases".
3. The CSR approver gave up. assisted-installer-controller approves CSRs during agent-based installs. assisted-service marked every host as error at 10:05, so the controller stopped approving at that point:
09:22:50 Hosts status: master-0:[installing-in-progress Waiting for bootkube] worker-0/1:[installing-in-progress Rebooting]
10:05:20 Hosts status: master-0:[error Waiting for bootkube] worker-0/1:[installing-pending-user-action Rebooting]
10:05:50 Hosts status: ... all 5 [error ...]
10:05:50 Finish approving CSRs
   The controller can't reach assisted-service any more either: Failed to upload logs ... Post "http://192.168.110.2:8090/...". That service ran on master-0's live image, and master-0 has since rebooted.
4. The nodes came back too late. Both master-0 and worker-0 booted from disk at about 10:11, a few minutes after the 10:05 cutoff. libvirt shows no VM restart since 08:31, so these were reboots inside the guests. That leaves about 45 minutes between "Rebooting" at 09:22 and the workers' first boot from disk at 10:08 that I can't account for. Those logs were on the live ISO and are gone.
worker-0: boot -1 10:08:21–10:10:52 (MCD firstboot reboot), boot 0 since 10:11:01
master-0: boot 0 since 10:11:02
5. Bootstrap never completed. The kube-system/bootstrap configmap doesn't exist, and etcd still lists the bootstrap member:
etcd: Degraded=True: 2 of 3 members are available, etcd-bootstrap is unhealthy
      CheckSafeToScaleCluster found 2 healthy member(s) out of the 3 required by the DelayedHAScalingStrategy
6. Everything else follows from having only 2 tainted masters. There are no worker nodes, so router, monitoring webhook and console-plugin pods are Pending with 0/2 nodes are available: 2 node(s) had untolerated taint(s). That in turn breaks ingress, auth, console and monitoring.

How to unblock it. Approve the pending CSRs by hand, twice: once for the client certs, then again a minute later for the serving certs.
ip vrf exec red oc --kubeconfig=$K get csr -o name | xargs ip vrf exec red oc --kubeconfig=$K adm certificate approve
master-0 should then join as the third etcd member, which should clear the etcd and bootstrap state. The workers should then let the ingress and monitoring pods schedule. I haven't approved anything yet. Should I go ahead?

That only works around the symptom. The real question is why the node reboots took about 45 minutes and bootkube on master-0 never finished; it was still "Waiting for bootkube" when it hit the time limit. The logs that would answer it are gone, so the next run should capture each node's console or serial log during the reboot phase.

---

The CSRs weren't approved because the installer gave up before the nodes registered. The underlying cause is the grout EVPN IP-mobility bug already described in deploys/28a_mac_mobility_bug.md: the API VIP stayed bound to master-0's MAC, so for about 45 minutes the workers couldn't reach the MCS and couldn't reboot into their installed disks.

How it unfolded

1. 09:12:40. master-0 (the bootstrap node, VTEP fd00::2) advertised the API VIP with its own MAC. On master-2:
rcvd RD 10.0.0.2:3 [2]:[0]:[48]:[52:54:00:b9:53:44]:[32]:[192.168.110.10]
grout neigh_install_nexthop: install remote nh iface=5 192.168.110.10 52:54:00:b9:53:44
   That MAC belongs to master-0:
master-0: br-ex 52:54:00:b9:53:44  192.168.110.2/24
master-2: br-ex 52:54:00:f5:10:de  192.168.110.4/24 192.168.110.10/32   <- real VIP owner
2. 09:18:51. keepalived on master-2 took the VIP ((sno-lab_API_0) Entering MASTER STATE). EVPN never moved the binding, so .10 still pointed at master-0's MAC.
3. 09:22. The workers' assisted-installer finished writing the disk and logged "Rebooting node". Your hackagent.sh (ignition-hack.service) keeps reboot.target masked and loops on curl https://192.168.110.10:22623/config/worker. The ip neigh del in that loop doesn't help, because neigh_suppress on br-pe-210 makes the PE answer ARP with the stale master-0 MAC. The production MCS on master-2 had been up since 09:11 but received no worker requests.
4. 10:05. The workers had been stuck in "Rebooting" for 43 minutes, and master-0 had been stuck in "Waiting for bootkube". assisted-service moved all hosts to error. assisted-installer-controller approves CSRs only while it's waiting for nodes, so it stopped:
10:05:20 Hosts status: master-0:[error Waiting for bootkube] worker-0/1:[installing-pending-user-action Rebooting]
10:05:50 Hosts status: ... all 5 [error ...]
10:05:50 Finish approving CSRs
5. 10:07:54. master-0's assisted-installer had exited, so its hack script went ahead with the reboot. master-0 left EVPN, and its stale route went with it:
10:07:54 GROUT: grout_vxlan_flood_update_ctx: del fd00::2 vni=210 vrf=1
6. 10:07:59. Five seconds later the workers reached the MCS for the first time:
10:07:59 Pool "worker" requested by address:"192.168.110.6" User-Agent:"curl/7.76.1"
10:08:01 Pool "worker" requested by address:"192.168.110.5" User-Agent:"curl/7.76.1"
   The workers booted from disk at 10:08 and master-0 at 10:11. All thret the controller had already stopped approving them, so they've been