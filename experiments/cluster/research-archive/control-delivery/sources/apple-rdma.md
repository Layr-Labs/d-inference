<!--
{
  "documentType" : "article",
  "framework" : "Technotes",
  "identifier" : "/documentation/Technotes/tn3205-low-latency-communication-with-rdma-over-thunderbolt",
  "metadataVersion" : "0.1.0",
  "role" : "article",
  "title" : "TN3205: Low-latency communication with RDMA over Thunderbolt"
}
-->

# TN3205: Low-latency communication with RDMA over Thunderbolt

Learn how to use RDMA over Thunderbolt to enable low-latency communication between clusters of Mac computers.

## Overview

RDMA over Thunderbolt enables high performance, peer-to-peer networking between
Mac computers connected with Thunderbolt. In particular, RDMA over Thunderbolt
exposes an RDMA (Remote Direct Memory Access) Verbs compatible API for the
Thunderbolt controller which enables carefully designed software to operate at
the hardware limits of Thunderbolt.

RDMA over Thunderbolt is available starting with macOS 26.2 on Macs with Apple
silicon with Thunderbolt 5.

## Enabling RDMA over Thunderbolt

To use RDMA over Thunderbolt, first enable it in macOS Recovery:

1. [Reboot into macOS Recovery](https://support.apple.com/en-us/102518/).
2. Open Terminal by choosing Utilities -> Terminal.
3. Run `rdma_ctl enable`.
4. Reboot back into macOS.
5. Check for RDMA over Thunderbolt interfaces with `ibv_devices`.

For example, after enabling RDMA over Thunderbolt, an M4 Pro Mac mini with
three Thunderbolt ports might look like this:

```sh
% ibv_devices
    device                 node GUID
    ------              ----------------
    rdma_en2            e0c5797d9c8fac05
    rdma_en3            e1c5797d9c8fac05
    rdma_en4            e2c5797d9c8fac05
```

In a cluster of four M4 Pro Mac minis, each interface becomes PORT_ACTIVE when
all connected Mac computers have RDMA enabled:

```sh
% ibv_devinfo
hca_id:    rdma_en2
    transport:            Thunderbolt (100)
...
    phys_port_cnt:            1
        port:    1
            state:            PORT_ACTIVE (4)
...

hca_id:    rdma_en3
    transport:            Thunderbolt (100)
...
    phys_port_cnt:            1
        port:    1
            state:            PORT_ACTIVE (4)
...

hca_id:    rdma_en4
    transport:            Thunderbolt (100)
...
    phys_port_cnt:            1
        port:    1
            state:            PORT_ACTIVE (4)
```

## RDMA over Thunderbolt and IP over Thunderbolt

Thunderbolt already provides [IP over Thunderbolt](https://support.apple.com/guide/mac-help/ip-thunderbolt-connect-mac-computers-mchld53dd2f5/mac) to allow
IP-based connectivity between devices. IP interfaces work well for tasks such
as SSH, NFS or HTTPS but have higher latency and CPU overhead than equivalent
RDMA interfaces. IP over Thunderbolt works in parallel to RDMA and the
Thunderbolt hardware load-balances between the two protocols.

### Disabling the Thunderbolt Bridge

The default IP over Thunderbolt configuration bridges all Thunderbolt ports
into a single network using an Ethernet bridge which looks as follows:

```sh
% ifconfig bridge0
bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
...
    member: en2 flags=3<LEARNING,DISCOVER>
            ifmaxaddr 0 port 11 priority 0 path cost 0
    member: en3 flags=3<LEARNING,DISCOVER>
            ifmaxaddr 0port 12 priority 0 path cost 0
    member: en4 flags=3<LEARNING,DISCOVER>
            ifmaxaddr 0 port 13 priority 0 path cost 0
...
    status: active
```

A bridge works like a physical Ethernet hub, so when an Ethernet frame arrives
on interface `en2`, the bridge forwards it to interfaces `en3` and `en4`. This
forwarding can pose a problem in clusters if either `en3` or `en4`  forms a
loop with `en2` as frames can then travel indefinitely, consuming excessive CPU
time and compromising network performance.

> important: Disable the Thunderbolt bridge when connecting Macs in loops.
> Open System Settings, navigate to Network, select the “Thunderbolt Bridge”
> and press [ Make Inactive ] to disable the bridge.

### RDMA over Thunderbolt Addressing

The RDMA Verbs API addresses peers using a 128-bit address, or GID, which
corresponds directly with an IP address on a paired Thunderbolt IP interface.
Consider the following Thunderbolt IP interface `en2` with IP addresses
`169.254.205.255` and `fe80::1021:1bac:fe1:b5e3`:

```sh
% ifconfig en2
en2: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    options=460<TSO4,TSO6,CHANNEL_IO>
    ether 02:00:00:00:00:01
    inet6 fe80::1021:1bac:fe1:b5e3%en2 prefixlen 64 secured scopeid 0xb
    inet 169.254.205.255 netmask 0xffff0000 broadcast 169.254.255.255
    nd6 options=201<PERFORMNUD,DAD>
    media: autoselect <full-duplex>
    status: active
```

The RDMA interface `rdma_en2` thus has the following GID table with GIDs
`::ffff:169.254.205.255` and `fe80::1021:1bac:fe1:b5e3`:

```sh
% ibv_devinfo -d rdma_en2 -v
hca_id:    rdma_en2 transport:            Thunderbolt (100) node_guid:
9093:3a23:2588:ac05 ... port:    1 state:            PORT_ACTIVE (4)
...
            active_width:        8X (4)
            active_speed:        10.0 Gbps (4)
            GID[  0]:        fe80::344d:4ff:feea:4e40
            GID[  1]:        ::ffff:169.254.205.255
            GID[  2]:        fe80::1021:1bac:fe1:b5e3
```

## Example Topologies

All RDMA interfaces are point-to-point between Mac computers. For minimal
latency, connect each Mac to every other Mac within a cluster to form a
fully-connected topology. However, because RDMA over Thunderbolt creates
point-to-point connections, many other topologies are possible. In particular,
a ring topology can allow connecting more Mac computers than Thunderbolt ports
at the cost of requiring the application to forward data.

With two Mac computers, form a fully-connected cluster by connecting with a
Thunderbolt cable between `en2` on Mac 1 and `en2` on Mac 2:

```
┌─────────┬───────┐         ┌───────┬─────────┐
│         │  en2  ◄─────────►  en2  │         │
│         ├───────┤         ├───────┤         │
│  Mac 1  │  en3  │         │  en3  │  Mac 2  │
│         ├───────┤         ├───────┤         │
│         │  en4  │         │  en4  │         │
└─────────┴───────┘         └───────┴─────────┘
```

Connect Three Mac computers with three Thunderbolt cables using the following
connections:

- Mac 1 `en2` connects to Mac 2 `en2`.
- Mac 1 `en3` connects to Mac 3 `en2`.
- Mac 2 `en3` connects to Mac 3 `en3`.

```
┌─────────┬───────┐         ┌───────┬─────────┐
│         │  en2  ◄─────────►  en2  │         │
│         ├───────┤         ├───────┤         │
│  Mac 1  │  en3  ◄─┐  ┌────►  en3  │  Mac 2  │
│         ├───────┤ │  │    ├───────┤         │
│         │  en4  │ │  │    │  en4  │         │
└─────────┴───────┘ │  │    └───────┴─────────┘
                    │  │
┌─────────┬───────┐ │  │
│         │  en2  ◄─┘  │ 
│         ├───────┤    │ 
│  Mac 3  │  en3  ◄────┘
│         ├───────┤
│         │  en4  │
└─────────┴───────┘ 
```

For a four node cluster, connect four Mac computers with six Thunderbolt cables
using the following cabling:

- Mac 1 `en2` connects to Mac 2 `en2`.
- Mac 1 `en3` connects to Mac 3 `en2`.
- Mac 1 `en4` connects to Mac 4 `en2`.
- Mac 2 `en3` connects to Mac 3 `en3`.
- Mac 2 `en4` connects to Mac 4 `en3`.
- Mac 3 `en4` connects to Mac 4 `en4`.

```
┌─────────┬───────┐         ┌───────┬─────────┐
│         │  en2  ◄─────────►  en2  │         │
│         ├───────┤         ├───────┤         │
│  Mac 1  │  en3  ◄─┐ ┌─────►  en3  │  Mac 2  │
│         ├───────┤ │ │     ├───────┤         │
│         │  en4  ◄─┼─┼─┐ ┌─►  en4  │         │
└─────────┴───────┘ │ │ │ │ └───────┴─────────┘
                    │ │ │ │
┌─────────┬───────┐ │ │ │ │ ┌───────┬─────────┐
│         │  en2  ◄─┘ │ └─┼─►  en2  │         │
│         ├───────┤   │   │ ├───────┤         │
│  Mac 3  │  en3  ◄───┘   └─►  en3  │  Mac 4  │
│         ├───────┤         ├───────┤         │
│         │  en4  ◄─────────►  en4  │         │
└─────────┴───────┘         └───────┴─────────┘
```

To connect five nodes, use a ring topology as follows:

- Mac 1 `en2` connects to Mac 2 `en2`.
- Mac 1 `en4` connects to Mac 3 `en2`.
- Mac 2 `en4` connects to Mac 4 `en2`.
- Mac 4 `en4` connects to Mac 5 `en4`.
- Mac 5 `en2` connects to Mac 3 `en4`.

```
┌─────────┬───────┐         ┌───────┬─────────┐
│         │  en2  ◄─────────►  en2  │         │
│         ├───────┤         ├───────┤         │
│  Mac 1  │  en3  │         │  en3  │  Mac 2  │
│         ├───────┤         ├───────┤         │
│         │  en4  ◄┐       ┌►  en4  │         │
└─────────┴───────┘│       │└───────┴─────────┘
                   │       │
┌─────────┬───────┐│       │┌───────┬─────────┐
│         │  en2  ◄┘       └►  en2  │         │
│         ├───────┤         ├───────┤         │
│  Mac 3  │  en3  │         │  en3  │  Mac 4  │
│         ├───────┤         ├───────┤         │
│         │  en4  ◄┐       ┌►  en4  │         │
└─────────┴───────┘│       │└───────┴─────────┘
                   │       │
                 ┌─▼─┬───┬─▼─┐
                 │en2│en3│en4│
                 ├───┴───┴───┤
                 │   Mac 5   │
                 └───────────┘
```

RDMA over Thunderbolt can’t route data and thus the application is responsible
for forwarding data as a particular topology requires. For example, in the five
node ring topology, a user can’t connect Mac 4 with Mac 1 without the
application forwarding data via Mac 2.

For some workloads, such as collective communication operations, applications
might allow intermediate nodes to perform portions of the computation rather
than merely forwarding bytes. Consider an “All Sum” operation where each node
adds its buffer to every other node’s buffer. Rather than forward all buffers
to one node which performs the addition, intermediate nodes might receive from
one neighbor, add their buffer to the running sum, then forward the result to
the next neighbor.

## Configuring Systems for Cluster Use

Mac clusters work best with a few macOS settings tuned for cluster use.

### Disable Idle Sleep

To ensure uninterrupted network access, disable sleep by following the 
[
instructions to stop automatic sleeping when the display is
off](https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac).

Without this, you may not be able to reach connected Macs over Thunderbolt
using IP or RDMA because Thunderbolt does not support Wake-on-LAN.

### Enable Automatic Login

To make remote access easier, set a macOS device to automatically log in as a
particular user by following the instructions under 
[How to log in
automatically to a Mac user account](https://support.apple.com/en-us/102316).

### Start Up After Power Failure

To ensure you can remotely access your Mac cluster after a power outage, open
System Settings, navigate to Energy, and toggle “Start up automatically after a
power failure”.

## Usage with MLX

RDMA over Thunderbolt was co-developed and optimized for 
[MLX Distributed and the
`jaccl` distributed compute backend](https://ml-explore.github.io/mlx/build/html/usage/distributed.html#jaccl-section). For ML tasks like
distributed inference, MLX should work out of the box with RDMA over
Thunderbolt.

## RDMA Verbs API Usage

The RDMA Verbs API is available for developers to use directly and
independently of MLX. To use RDMA Verbs, include `infiniband/verbs.h` and link
against `librdma.tbd` in the macOS SDK.

RDMA over Thunderbolt supports:

- Send and receive operations only
- A maximum of 10 unreliable connection (UC) queue pairs
- Message sizes of up to 16,773,120 bytes
- A maximum of 4095 work requests at a time

If you’re familiar with RDMA Verbs on other platforms, you should find yourself
right at home. If you are new to this API, read the introduction below and
refer to the 
[JACCL backend for MLX
Distributed](https://github.com/ml-explore/mlx/tree/8017d438a97308f8e36f990a849c48e23cc80afc/mlx/distributed/jaccl)
for example code.

### Listing devices

To discover RDMA Verbs interfaces, use the `ibv_get_device_list` function and the
`ibv_get_device_name` function to fetch the interface name:

```c
struct ibv_device **device_list = ibv_get_device_list(NULL);
if (device_list == NULL) {
  printf("Failed to get device list!\n");
  // … handle error …
}
int devices_found = 0;
for (int i = 0; device_list[i]; i++) {
  devices_found += 1;
  printf("Found RDMA Verbs device with name: %s\n", ibv_get_device_name(device_list[i]));
}
printf("Found %d RDMA Verbs devices\n", devices_found);
```

The device name might be `rdma_en2` for the RDMA over Thunderbolt interface
paired with the Thunderbolt IP interface `en2`. Be sure to free the
dynamically-allocated device list with `ibv_free_device_list` when the program
is done interacting with RDMA Verbs devices.

### Opening a device and mapping memory

Once an application has identified the RDMA Verbs network interface, it should
open the device using `ibv_open_device` to get a context that can be used to
allocate RDMA Verbs resources:

```c
// pick a device returned from ibv_get_device_list
struct ibv_device *device = device_list[0];

struct ibv_context *context = ibv_open_device(device);
if (context == NULL) {
  printf("Failed to open device\n");
  // … handle error …
}
```

On Macs with Apple Silicon, each Thunderbolt controller sits behind an
[IOMMU](https://support.apple.com/guide/security/direct-memory-access-protections-seca4960c2b5/web) and thus can only access memory mapped specifically for each
controller. Using RDMA Verbs, we can register memory visible to the Thunderbolt
controller by creating a protection domain and registering memory regions
within it.

First, allocate page-aligned memory of arbitrary length using `posix_memalign`:

```c
void *buffer;
size_t buffer_size = getpagesize() * 4; // 64 KiB (4 pages)
int err = posix_memalign(&buffer, getpagesize(), buffer_size);
if (err != 0) {
  printf("Failed to allocate aligned memory\n");
  // … handle error …
}
```

Next, allocate a protection domain:

```c
struct ibv_pd *protection_domain = ibv_alloc_pd(context);
if (context == NULL) {
  printf("Failed to allocate protection domain\n");
  // … handle error …
}
```

Finally, register the page-aligned memory as a memory region so the Thunderbolt
controller can access it through the IOMMU:

```c
struct ibv_mr *memory_region = ibv_reg_mr(
    protection_domain, buffer, buffer_size, IBV_ACCESS_LOCAL_WRITE);
if (memory_region == NULL) {
  printf("Failed to register memory region\n");
  // … handle error …
}
```

> note: RDMA over Thunderbolt only supports 2-sided operations and not
> hardware-initiated remote writes, thus applications should only register
> memory as `IBV_ACCESS_LOCAL_WRITE`.

### Setting up queue pair connections

A queue pair holds RDMA Verbs connection state from a host to a particular peer,
just as a socket holds connection state for a TCP connection.

All queue pair operations are *non-blocking* and the caller must poll an
associated completion queue for completion events.

To allocate a completion queue, use `ibv_create_cq`:

```c
int completion_queue_depth = 4095;
struct ibv_cq *completion_queue =
    ibv_create_cq(context, completion_queue_depth + 1, NULL, NULL, 0);
if (!completion_queue) {
  printf("Couldn't create RDMA Verbs completion queue\n");
  // … handle error …
}
```

Next, an application can create a queue pair with `ibv_create_qp`. When
creating queue pairs, applications can request hardware queue depths up to 4095
using the `max_send_wr` and `max_recv_wr` fields of the `ibv_qp_init_attr`
structure:

```c
struct ibv_qp_init_attr queue_pair_init_attr = {
    .send_cq = completion_queue,
    .recv_cq = completion_queue,
    .cap = {.max_send_wr = completion_queue_depth,
            .max_recv_wr = completion_queue_depth,
            .max_send_sge = 1,
            .max_recv_sge = 1},
    .qp_type = IBV_QPT_UC};

struct ibv_qp *queue_pair =
    ibv_create_qp(protection_domain, &queue_pair_init_attr);
if (queue_pair == NULL) {
  printf("Couldn't create RDMA Verbs queue pair\n");
  // … handle error …
}
```

Deeper hardware queues allow for queuing more work at a time which can improve
bandwidth performance, especially when sending RDMA messages which span
multiple Thunderbolt frames. Queues are sized in units of 4 KB frames. For
example, two 4 KB sends and a single 8 KB send would both take up 2 queue
spaces. Thus, queue depths set the maximum message size possible. For example,
a queue depth of 1024 frames would allow sending a message of size
1024 * 4096 = 4,194,304 bytes whereas a queue depth of 4095 would allow message
sizes of up to 4095 * 4096 = 16,773,120 bytes.

Finally, query the assigned attributes for the queue pair. The system may
adjust queue depths based on hardware capabilities so be sure to check final
values using `ibv_query_qp`:

```c
struct ibv_qp_attr queue_pair_attr;
ibv_query_qp(queue_pair, &queue_pair_attr, IBV_QP_CAP, &queue_pair_init_attr);
```

Newly-created queue pairs start off in the “Reset” state (`IBV_QPS_RESET`). To
connect to a peer, an application must carry out a series of queue pair state
transitions on the queue pair which end with the queue pair in the “Ready to
Send” (`IBV_QPS_RTS`) state to connect to a corresponding queue pair on a peer.

First, transition the new queue pair to the “Init” state (`IBV_QPS_INIT`),
specifying the physical port number intended to be used with RDMA over
Thunderbolt:

```c
struct ibv_qp_attr init_qp_attr = {.qp_state = IBV_QPS_INIT,
                                   .pkey_index = 0,
                                   .port_num = 1,
                                   .qp_access_flags = 0};

if (ibv_modify_qp(queue_pair, &init_qp_attr,
                  IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                      IBV_QP_ACCESS_FLAGS)) {
  printf("Failed to transition RDMA Verbs queue pair to INIT\n");
  // … handle error …
}
```

With RDMA over Thunderbolt, the port number is typically 1 as Apple Thunderbolt
controllers have a single port which is reflected in the `ibv_devinfo` output.

At this point, applications should use an out-of-band communication mechanism
to share the GID and queue pair number (QPN) with a peer. Typically
applications use Thunderbolt IP and a TCP socket connection for this purpose,
but any reliable mechanism of exchanging this metadata works.

In particular, applications should fetch metadata with `ibv_query_port` and
`ibv_query_gid`:

```c
struct ibv_port_attr port_attr = {};
// Query port 1's attributes
ibv_query_port(context, 1, &port_attr);

union ibv_gid peer_gid = {};

// Query the GID at index 1 on port 1
ibv_query_gid(context, 1, 1, &peer_gid);
uint16_t peer_local_id = port_attr.lid;
uint32_t peer_queue_pair_number = queue_pair->qp_num;
uint32_t peer_packet_sequence_number = 7; // pick a random number
```

Once an application has exchanged the queue pair metadata, it should prepare
the queue pair for receiving data from its peer by transitioning the queue pair
to the “Ready to Receive” state (`IBV_QPS_RTR`):

```c
struct ibv_qp_attr queue_pair_rtr_attr = {
    .qp_state = IBV_QPS_RTR,
    .path_mtu = IBV_MTU_4096,
    .rq_psn = peer_packet_sequence_number,
    .dest_qp_num = peer_queue_pair_number,
    .ah_attr =
        {
            .dlid = peer_local_id,
            .sl = 0,
            .src_path_bits = 0,
            .port_num = 1,
            .is_global = 1,
            .grh =
                {
                    .hop_limit = 1,
                    .dgid = peer_gid,
                    .sgid_index = 1,
                },
        },
};

if (ibv_modify_qp(queue_pair, &queue_pair_rtr_attr,
                  IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                      IBV_QP_DEST_QPN | IBV_QP_RQ_PSN)) {
  printf("Failed to transition RDMA Verbs queue pair to RTR\n");
  // … handle error …
}
```

When the queue pair is “Ready to Receive”, the Thunderbolt controller will
start processing receive requests, but not send requests on behalf of the queue
pair. To allow sending data, an application should transition the queue pair to
“Ready to Send” (`IBV_QPS_RTS`):

```c
struct ibv_qp_attr queue_pair_rts_attr = {
    .qp_state = IBV_QPS_RTS,
    .sq_psn = 7, // pick random packet sequence number
};
if (ibv_modify_qp(queue_pair, &queue_pair_rts_attr,
                  IBV_QP_STATE | IBV_QP_SQ_PSN)) {
  printf("Failed to modify RDMA Verbs queue pair to RTS\n");
  // … handle error …
}
```

After a successful transition to “Ready to Send”, the application can freely
send and receive data from its peer using the new queue pair.

### Preparing to receive

Once an application has connected a queue pair to its peer as described above,
it can post a receive work request (WR) to indicate to the Thunderbolt hardware
where incoming data should be written. When a sender sends a matching frame,
the Thunderbolt controller directly copies the data into the address specified
in the receive work request.

For example, the receiver can receive into the second page of the buffer we
registered earlier by calling `ibv_post_recv` to post a receive operation to
the Thunderbolt hardware:

```c
// Receive buffer can be anywhere within a registered memory region 
// In this example, receive into the first page of the memory region
void *receive_buffer = buffer;
struct ibv_sge receive_scatter_gather_list = {
    .addr = (uintptr_t)receive_buffer, // Userspace virtual address
    .length = getpagesize(),
    .lkey = memory_region->lkey // Local key set by kernel in ibv_reg_mr
};
const uint32_t receive_work_request_id = 1;
struct ibv_recv_wr receive_work_request = {
    // Match with send on other side
    .wr_id = receive_work_request_id,
    .sg_list = &receive_scatter_gather_list,
    .num_sge = 1,
};
struct ibv_recv_wr *bad_receive_wr;

ibv_post_recv(queue_pair, &receive_work_request,
              &bad_receive_wr); // non-blocking and no syscall made
```

`ibv_post_recv` will return immediately and the Thunderbolt hardware will
report completion of the receive to the queue pair’s associated completion
queue.

> note: Thunderbolt devices require a receiver and sender to post messages
> which are the same number of frames long. For example, if the sender sends a
> 16K message and the receiver posts a 4K or 32K receive buffer the receive
> operation will fail.

### Preparing to send

To send data to a peer, applications should call `ibv_post_send` to send data
from a pre-registered buffer. The Thunderbolt controller hardware ensures this
send work request isn’t processed until the receiving Mac has posted a matching
receive work request using a credit-based flow control system.

The sender can send the first page of the buffer registered earlier using the
following RDMA Verbs API calls to post a send operation to the Thunderbolt hardware:

```c
// Send buffer can be anywhere within registered memory region
// In this example, send the second page of the memory region such that it will
// be received into the receive buffer in the first page of the memory region
void *send_buf = (void *)buffer + getpagesize();
const char testString[] = "Hello RDMA!";
memcpy(send_buf, testString, sizeof(testString));
struct ibv_sge send_scatter_gather_list = {
    .addr = (uintptr_t)send_buf, // Userspace virtual address
    .length = getpagesize(),
    .lkey = memory_region->lkey};

const uint32_t send_work_request_id = receive_work_request_id + 1;
struct ibv_send_wr send_work_request = {
    .wr_id = send_work_request_id,
    .sg_list = &send_scatter_gather_list,
    .num_sge = 1,
    .opcode = IBV_WR_SEND, // Only IBV_WR_SEND is supported
    .send_flags = IBV_SEND_SIGNALED,
};
struct ibv_send_wr *bad_send_wr;

ibv_post_send(queue_pair, &send_work_request,
              &bad_send_wr); // non-blocking and no syscall made
```

`ibv_post_send` will return immediately and the Thunderbolt hardware will
report completion of the send to the queue pair’s associated completion queue.

> note: Completion of a send operation indicates that the peer has posted
> sufficient receive requests to receive all sent frames and that the
> Thunderbolt hardware has sent the buffers to the peer. Completion does not
> indicate the receiver has successfully received the sent data or that data
> was not corrupted in flight because Thunderbolt does not perform Acks in
> hardware.

### Polling for completion

To check work requests for completion, poll for completion using
`ibv_poll_cq`. The Thunderbolt controller reports failures to send or
receive in the work completion (WC) status field.

For example, this sort of polling can be expressed in a for loop:

```c
struct ibv_wc work_completions[2];
int completions_polled;
do {
  // Polls Thunderbolt send descriptors directly without making syscalls
  completions_polled = ibv_poll_cq(completion_queue, 2, work_completions);
  assert(completions_polled >= 0);
} while (completions_polled < 1);
for (int i = 0; i < completions_polled; ++i) {
  assert(work_completions[i].status == IBV_WC_SUCCESS);
  switch ((int)work_completions[i].wr_id) {
  case send_work_request_id:
    // Send complete
    break;
  case receive_work_request_id:
    // Receive complete
    break;
  }
}
```

## Revision History

- **2026-04-13** Added a section about configuring Macs for cluster use.
- **2026-03-19** First published.

---

Copyright &copy; 2026 Apple Inc. All rights reserved. | [Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html) | [Privacy Policy](https://www.apple.com/privacy/privacy-policy)