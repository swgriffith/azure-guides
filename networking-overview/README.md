# AKS Networking Overview

## Topics

In this session we're going to deep dive into the network stack associated with both Kubenet and Azure CNI, to help explain how they work internally, how they can be debugged the pros and cons of each.

* Outbound Type: Check out the session from [@RayKao](https://twitter.com/raykao)...[here](https://www.youtube.com/channel/UCvdABD6_HuCG_to6kVprdjQ)
* Network Plugin
  * [Kubenet](./part1-kubenet.md)
  * [Azure CNI](./part2azurecni.md)
* Windows Networking
  * [Great Overview](https://techcommunity.microsoft.com/t5/networking-blog/introducing-kubernetes-overlay-networking-for-windows/ba-p/363082)
  * Details (Linux --> Windows):
    * Azure CNI Required
      * Supported in [AKS Engine](https://github.com/Azure/aks-engine/blob/master/examples/windows/kubernetes-hybrid.kubenet-containerd.json) and an open issue exists to promote this capability to AKS. See issue [#1244](https://github.com/Azure/AKS/issues/1244)
    * Linux Bridge --> Host Networking Service
    * iptables --> vSwitch + Virtual Filtering Platform + Distributed Router
* Network Policy: None/Azure/Calico
* [How iptables come into play](./iptables.md)
* Debugging
  * [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump) - Create a jump server pod in your cluster and tunnels ssh through kubernetes port-forward
  * tcpdump - Native Linux command line tool. Run in host or pod. Check out this zine from [Julia Evans - @b0rk](https://twitter.com/b0rk)....[tcpdump](https://wizardzines.com/zines/tcpdump/)
  * [ksniff](https://github.com/eldadru/ksniff) - Creates a tcpdump proxy and can stream directly to [Wireshark](https://www.wireshark.org/)



## Network Feature Status
| Feature | Status | Notes |
| ------- | ------ | ----- |
| IPVS vs. IPTables | No Current Plan | Transition to IPVS over IPTables has been considered, but the known stability of IPTables has won out over IPVS, for the time being. Feel free to contribute to the discussion in the AKS github under issue [#1846](https://github.com/Azure/AKS/issues/1846) |
| IPv6 | [Backlog](https://github.com/Azure/AKS/issues/460) | IPv6 is still in alpha state in upstream Kubernetes, so not ready for production workloads. You can track the status under [sig-networking](https://github.com/kubernetes/enhancements/issues?q=is%3Aopen+label%3Asig%2Fnetwork+ipv6). Microsoft has been heavily involved in it's development, so I hoped to see adoption in AKS pretty rapidly, but not dates have yet been shared. |
| Nodepool Subnet | [Public Preview](https://github.com/Azure/AKS/issues/1338) | Allows you to chose the target subnet at the nodepool level rather than at the cluster level. Currently Azure CNI only, but Kubenet is [planned](https://github.com/Azure/AKS/issues/1500) |
| Calico on Windows | [In Progress](https://github.com/Azure/AKS/issues/1681) | Adds support for open source Calico Kubernetes Network Policy in AKS for Windows |



