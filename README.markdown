# nprocreg - Minimal Distributed Erlang Process Registry

nprocreg is a global process registry built for Nitrogen. The goal
of nprocreg is to allow Key-based lookups of a Pid, and if no Pid
is found, to start a new process based on a provided Function,
load-balanced newly spawned functions across the cluster.

The nprocreg gen_server, when run on a node in a Nitrogen cluster,
will automatically connect to other nprocreg servers in other
nodes in the cluster.

Nodes discover eachother by broadcasting out their existence to
all other nodes in the cluster, retrieved by nodes(). When a node
receives a message from another node, it updates a state variable,
tracking the node. If enough time has passed since the last
checkin, the node is removed, because we assume that the
application has stopped. (Note that the node itself might still be
available, we ignore this fact.)

The case that we must be careful of is when two processes look up
the same Key at the same time on different nodes, potentially
leading multiple Pids associated with the same key. To avoid this
problem, we hash the Key to a node, and try to start the process
on that node. This effectively makes process creation single
threaded, drastically reducing the opportunity of creating
conflicting Pids. Note that this opportunity still exists: when a
new node running nprocreg is started, or an existing one is
stopped, different nodes could have a different view of which
nodes are available. This will happen so infrequently, and for
such a short time, that we just ignore it.

nprocreg is used by the Nitrogen Web Framework.
