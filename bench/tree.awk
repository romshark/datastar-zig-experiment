# Sum resident memory (KB) and cumulative CPU time (seconds) over the process
# tree rooted at `root`, including all descendants (e.g. the Go server's sqinn
# child). Input is `ps -axo pid=,ppid=,rss=,cputime=`.
#
# Prints: "<rssKB> <cpuSecs>"

# Parse a ps cputime field into seconds. Formats: MM:SS, MM:SS.ss (macOS),
# HH:MM:SS, DD-HH:MM:SS (Linux).
function parsect(s,   i, n, days, parts, t) {
    days = 0
    i = index(s, "-")
    if (i > 0) { days = substr(s, 1, i - 1) + 0; s = substr(s, i + 1) }
    n = split(s, parts, ":")
    t = 0
    for (i = 1; i <= n; i++) t = t * 60 + parts[i]
    return days * 86400 + t
}

{
    pids[$1] = 1
    rss[$1] = $3 + 0
    cpu[$1] = parsect($4)
    children[$2] = children[$2] " " $1
}

END {
    stack[0] = root; sp = 1
    totrss = 0; totcpu = 0
    while (sp > 0) {
        sp--; p = stack[sp]
        if (seen[p]) continue
        seen[p] = 1
        if (p in pids) { totrss += rss[p]; totcpu += cpu[p] }
        n = split(children[p], kids, " ")
        for (i = 1; i <= n; i++) if (kids[i] != "") { stack[sp] = kids[i]; sp++ }
    }
    printf "%d %.3f\n", totrss, totcpu
}
