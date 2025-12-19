#!/usr/sbin/dtrace -s

/* Trace load balancer worker activity */

/* Trace accept() calls - shows which process accepts connections */
syscall::accept:return
/execname == "load_balancer_mp"/
{
    printf("PID %d accepted connection, fd=%d\n", pid, arg1);
}

/* Trace read/write to see request handling */
syscall::read:entry
/execname == "load_balancer_mp" && arg2 > 0/
{
    @reads[pid] = count();
}

syscall::write:entry
/execname == "load_balancer_mp" && arg2 > 0/
{
    @writes[pid] = count();
}

/* Trace connect() - shows backend connections */
syscall::connect:entry
/execname == "load_balancer_mp"/
{
    printf("PID %d connecting to backend\n", pid);
}

/* Summary every 5 seconds */
tick-5s
{
    printf("\n=== Activity by PID ===\n");
    printf("Reads:\n");
    printa("  PID %d: %@d reads\n", @reads);
    printf("Writes:\n");
    printa("  PID %d: %@d writes\n", @writes);
    clear(@reads);
    clear(@writes);
}
