locker
==

A local synchronization library for an erlang applications.

Example usage:

```erlang
    locker:lock({some, term}),
    % do something
    locker:unlock({some, term}).
```

Functions brief:

* `lock/{1,2}` -- wait for release of resource, then lock it (sync);
* `trylock/1` -- tries to lock the resource; fails if the resource is already locked;
* `islocked/1` -- returns true if the resource is locked by caller process, otherwise return false;
* `withlock/2` -- executes a given function under captured lock;
* `lend/2` -- if process-executor have captured lock, `lend` tries to pass ownership of locked resource
  to another process, which is identified by given PID.

You can obtain more information in sources: `src/locker.erl`
