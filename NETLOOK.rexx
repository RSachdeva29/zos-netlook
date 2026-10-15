/* REXX */
/*                                                                   */
/* NETLOOK - Mainframe network lookup for z/OS systems programmers   */
/*                                                                   */
/* Purpose : Overview of the z/OS network setup and help with        */
/*           network problem diagnosis: which job/STC and LPAR own   */
/*           a port or IP, whether it is listening, and what is      */
/*           connected to what - no network expertise needed.        */
/*                                                                   */
/* How     : Issues D TCPIP,<stack>,NETSTAT commands (ALLCONN,       */
/*           PORTLIST, HOME, VIPADYN) to every LPAR in the sysplex   */
/*           through SDSF REXX (ISFSLASH + RO), parses the replies,  */
/*           and builds a report.                                    */
/*                                                                   */
/* Usage   : ISPF : TSO %NETLOOK  (or EX 'lib(NETLOOK)') - menu      */
/*           TSO  : %NETLOOK ALL              (health check)         */
/*                  %NETLOOK PORT 8443                               */
/*                  %NETLOOK IP   10.1.2.3                           */
/*                  %NETLOOK HOST app.example.com                    */
/*                  %NETLOOK JOB  CICSPRD1                           */
/*           Options: LPAR(sysname)  limit to one LPAR               */
/*                    STACK(procnm)  override TCP/IP proc name       */
/*                    DEBUG          show raw command replies        */
/*                    TEST(dir)      replay sample output (testing)  */
/*                                                                   */
/* Requires: SDSF REXX; authority to issue D TCPIP and RO (see       */
/*           README). Read-only: NETLOOK only issues DISPLAY cmds.   */
/*                                                                   */
/* Author  : Rama Sachdeva                                           */
/* License : Apache-2.0                                              */
/* ----------------------------------------------------------------- */
ver = '1.5'
/* ===================== Site configuration ======================== */
stackname.      = 'TCPIP' /* default TCP/IP stack proc name        */
/* stackname.SYSB = 'TCPIPB'   per-LPAR override, if names differ    */
cfg.panlib = 'YOUR.NETLOOK.PANELS'  /* library with NETLOOK panels */
cfg.syslist     = ''        /* LPARs to query; blank = discover via  */
                            /* SDSF SYS panel, else current LPAR     */
cfg.delay       = 5         /* seconds to wait for command replies   */
cfg.maxopt      = ',MAX=*'  /* NETSTAT record limit (* = all)        */
cfg.rptdsn      = ''        /* ISPF report DSN; blank=userid.NETLOOK.*/
cfg.width       = 79        /* report line width                     */
cfg.rdns        = 1         /* 1 = show host names for remote IPs    */
/* ================================================================== */
parse source srcenv .
onHost = (srcenv = 'TSO')
parse arg argline
if onHost & strip(argline) = '' then
  if sysvar('SYSISPF') = 'ACTIVE' then do
    call PanelLoop
    exit 0
  end
errmsg = ParseArgs(argline)
if errmsg <> '' then do
  say 'NETLOOK:' errmsg
  call Usage
  exit 8
end
call Run
call ShowReport
exit worst
/* ================================================================= */
/* ISPF front end                                                    */
/* ================================================================= */
PanelLoop:                            /* main menu: NETLOOKP       */
  address ispexec
  'CONTROL ERRORS RETURN'
  "LIBDEF ISPPLIB DATASET ID('"cfg.panlib"')"
  nltype = 'PORT'; nlvalue = ''; nllpar = ''; nlhlpar = ''
  'VGET (NLTYPE NLVALUE NLLPAR NLHLPAR) PROFILE'
  do forever
    'DISPLAY PANEL(NETLOOKP)'
    if rc > 0 then leave
    'VPUT (NLHLPAR) PROFILE'
    select
      when zcmd = '1' then do           /* health check              */
        a = 'ALL'
        if strip(nlhlpar) <> '' then a = a 'LPAR('strip(nlhlpar)')'
        call PanelRun a
      end
      when zcmd = '2' then call LookupLoop
      when zcmd = '3' then call ShowCmds
      otherwise nop
    end
  end
  "LIBDEF ISPPLIB"                      /* release panel library     */
  address
return
ShowCmds:                             /* command reference         */
  /* text lives at the end of this exec; write it out and BROWSE   */
  drop ref.; n = 0; on = 0
  do i = 1 to sourceline()
    l = sourceline(i)
    if l = 'NETCMDS-END' then leave
    if on then do; n = n + 1; ref.n = l; end
    if l = 'NETCMDS-START' then on = 1
  end
  ref.0 = n
  dsn = userid()'.NETLOOK.CMDS'
  if sysdsn("'"dsn"'") = 'OK' then
    call bpxwdyn "ALLOC FI(NLCMDS) DA('"dsn"') OLD REUSE"
  else
    call bpxwdyn "ALLOC FI(NLCMDS) DA('"dsn"') NEW CATALOG" ,
                 "RECFM(F,B) LRECL(80) TRACKS SPACE(1,1) REUSE"
  if result <> 0 then do
    zedsmsg = 'Alloc failed'
    zedlmsg = 'Could not allocate' dsn 'for the command reference.'
    'SETMSG MSG(ISRZ001)'
    return
  end
  address mvs 'EXECIO' ref.0 'DISKW NLCMDS (STEM REF. FINIS'
  call bpxwdyn 'FREE FI(NLCMDS)'
  "BROWSE DATASET('"dsn"')"
return
LookupLoop:                           /* lookup panel: NETLKUP     */
  do forever
    'DISPLAY PANEL(NETLKUP)'
    if rc > 0 then leave                /* PF3: back to the menu     */
    'VPUT (NLTYPE NLVALUE NLLPAR) PROFILE'
    a = nltype nlvalue
    if strip(nllpar) <> '' then a = a 'LPAR('strip(nllpar)')'
    call PanelRun a
  end
return
PanelRun:                             /* validate, run, show       */
  parse arg pa
  errmsg = ParseArgs(pa)
  if errmsg <> '' then do
    zedsmsg = 'Invalid input'
    zedlmsg = errmsg
    'SETMSG MSG(ISRZ001)'
    return
  end
  call Run
  call ShowReport
return
/* ================================================================= */
/* Argument parsing                                                  */
/* ================================================================= */
ParseArgs: procedure expose q. testdir cfg.
  parse upper arg a
  q. = ''
  testdir = ''
  parse var a q.type q.value rest
  if q.type = 'ALL' then do            /* ALL takes no value         */
    rest = q.value rest
    q.value = ''
  end
  /* keyword options: LPAR(x) PORT(n) STACK(x) TEST(dir) BATCH       */
  do while rest <> ''
    parse var rest kw rest
    if kw = 'BATCH' then iterate
    parse var kw key '(' val ')'
    select
      when key = 'LPAR'  then q.lpar  = val
      when key = 'PORT'  then q.port  = val
      when key = 'STACK' then q.stack = val
      when key = 'DEBUG' then q.debug = 1
      when key = 'TEST'  then do
        /* keep original case of the test directory (Unix paths)    */
        parse arg orig
        p = pos('TEST(', translate(orig))
        parse value substr(orig, p + 5) with testdir ')' .
      end
      otherwise return 'Unknown option:' kw
    end
  end
  if wordpos(q.type, 'IP PORT HOST JOB ALL') = 0 then
    return 'Lookup type must be IP, PORT, HOST, JOB or ALL.'
  if q.value = '' & q.type <> 'ALL' then
    return 'Enter a value to look up.'
  select
    when q.type = 'IP' then
      if \ValidIp(q.value) then return q.value 'is not a valid IP.'
    when q.type = 'PORT' then
      if \ValidPort(q.value) then return 'Port must be 1-65535.'
    when q.type = 'JOB' then
      if length(q.value) > 8 then return 'Job name: max 8 chars.'
    otherwise nop
  end
  /* names go into the D TCPIP / RO command text: allow only valid */
  /* z/OS name characters so nothing else can be slipped in         */
  if q.type = 'JOB' & \ValidName(q.value) then
    return 'Job/STC name has invalid characters.'
  if q.lpar  <> '' & \ValidName(q.lpar)  then
    return 'LPAR name has invalid characters.'
  if q.stack <> '' & \ValidName(q.stack) then
    return 'STACK name has invalid characters.'
  if q.port <> '' then do
    if wordpos(q.type, 'IP HOST') = 0 then
      return 'PORT() option is only used with IP or HOST lookups.'
    if \ValidPort(q.port) then return 'Port must be a number 1-65535.'
  end
return ''
ValidIp: procedure
  parse arg ip
  if ip = '' then return 0
  parse var ip o1 '.' o2 '.' o3 '.' o4 extra
  if extra <> '' then return 0
  do i = 1 to 4
    o = value('o'i)
    if \datatype(o, 'W') then return 0
    if o < 0 | o > 255 then return 0
  end
return 1
/* DEBUG helper: hide IP addresses (digits -> 9), keep the layout  */
MaskIp: procedure
  parse arg ml
  out = ''
  do w = 1 to words(ml)
    wd = word(ml, w)
    if pos('.', wd) > 0 | pos(':', wd) > 0 then
      if verify(translate(wd), '0123456789.:ABCDEF/') = 0 then
        wd = translate(wd, '9999999999', '0123456789')
    p = wordindex(ml, w)
    out = left(out, p - 1) || wd
  end
return out
ValidName: procedure                 /* 1-8 chars: A-Z 0-9 @ # $  */
  parse arg n
  if length(n) < 1 | length(n) > 8 then return 0
return verify(n, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$') = 0
ValidPort: procedure
  parse arg p
  if \datatype(p, 'W') then return 0
return (p >= 1 & p <= 65535)
Usage:
  say 'Usage: %NETLOOK IP   a.b.c.d  [PORT(n)] [LPAR(sys)]'
  say '       %NETLOOK PORT n                   [LPAR(sys)]'
  say '       %NETLOOK HOST name     [PORT(n)] [LPAR(sys)]'
  say '       %NETLOOK JOB  jobname             [LPAR(sys)]'
  say '       %NETLOOK ALL                      [LPAR(sys)]'
return
/* ================================================================= */
/* Main processing                                                   */
/* ================================================================= */
Run:
  /* reset all result stores between runs                           */
  drop conn. rsv. home. vip. act. note. rpt. find. step. ips.
  conn.0 = 0; rsv.0 = 0; home.0 = 0; vip.0 = 0
  note.0 = 0; rpt.0 = 0; find.0 = 0; step.0 = 0; ips.0 = 0
  drop cmdl.; cmdl.0 = 0
  act. = '?'
  actall = 0
  drop ph.; ph.0 = 0
  worst = 0
  deadsys = ''
  test = (testdir <> '')
  if \test & onHost then call rxSdsfOn
  call GetSystems
  if sys.0 = 0 then do
    call Note 'No LPARs to query.'
    call BuildReport
    return
  end
  need.allconn = 1
  need.portlist = wordpos(q.type, 'PORT JOB ALL') > 0 | q.port <> ''
  need.home    = wordpos(q.type, 'IP HOST') > 0
  need.vipadyn = need.home
  /* HOST: resolve to IPs first                                     */
  if q.type = 'HOST' then do
    call Resolve q.value
    if ips.0 = 0 then do                /* nothing to trace          */
      if \test & onHost then call rxSdsfOff2
      call BuildReport
      return
    end
  end
  else if q.type = 'IP' then do
    ips.0 = 1; ips.1 = q.value
  end
  do s = 1 to sys.0
    sy = sys.s
    stk = stackname.sy
    if q.stack <> '' then stk = q.stack
    if wordpos(sy, deadsys) > 0 then iterate
    /* no server-side filters: ALLCONN is read whole and filtered  */
    /* here, so every lookup uses the same command as ALL          */
    filt = ''
    if need.allconn  then call Collect sy, stk, 'ALLCONN'filt
    if need.portlist & wordpos(sy, deadsys) = 0 then ,
      call Collect sy, stk, 'PORTLIST'
    if need.home     & wordpos(sy, deadsys) = 0 then ,
      call Collect sy, stk, 'HOME'
    if need.vipadyn  & wordpos(sy, deadsys) = 0 then ,
      call Collect sy, stk, 'VIPADYN'
  end
  if ips.0 > 0 then call PruneListeners
  select
    when q.type = 'PORT' then call DiagPort q.value, ''
    when q.type = 'JOB'  then call DiagJob  q.value
    when q.type = 'ALL'  then call DiagAll
    otherwise do
      if ips.0 > 0 then
        do i = 1 to ips.0
          if ips.0 > 1 then call Find '--', '--- Address' ips.i '---'
          call DiagIp ips.i, q.port
        end
    end
  end
  if \test & onHost then call rxSdsfOff2   /* after DA checks      */
  call BuildReport
return
/* ================================================================= */
/* Data collection                                                   */
/* ================================================================= */
GetSystems:
  sys.0 = 0
  localsys = ''
  if test then do
    f = testdir'/SYSLIST.txt'
    do while lines(f) > 0
      l = strip(linein(f))
      if l = '' then iterate
      if localsys = '' then localsys = word(l, 1)
      call AddSys word(l, 1)
    end
    call stream f, 'C', 'CLOSE'
  end
  else do
    localsys = mvsvar('SYSNAME')
    if strip(cfg.syslist) <> '' then
      do i = 1 to words(cfg.syslist)
        call AddSys word(cfg.syslist, i)
      end
    else do
      isfcols = 'SYSNAME'
      drop sysname.                 /* no stale rows from a DA call */
      address SDSF 'ISFEXEC SYS'
      if rc = 0 & symbol('SYSNAME.0') = 'VAR' then
        do i = 1 to sysname.0
          call AddSys sysname.i
        end
      isfcols = ''
      if sys.0 = 0 then call AddSys localsys
    end
  end
  /* LPAR() given: query exactly that LPAR, even if discovery     */
  /* missed it (RO will say so if it does not exist)               */
  if q.lpar <> '' then do
    sys.0 = 0
    call AddSys q.lpar
  end
return
AddSys:
  parse upper arg nm .
  do si = 1 to sys.0
    if sys.si = nm then return
  end
  si = sys.0 + 1
  sys.si = nm
  sys.0 = si
return
/* Issue one D TCPIP NETSTAT command and parse its reply             */
Collect:
  parse arg csys, cstk, creport
  kind = creport
  parse var kind kind ',' .
  out.0 = 0
  if test then do
    f = testdir'/'csys'_'kind'.txt'
    n = 0
    do while lines(f) > 0
      n = n + 1
      out.n = linein(f)
    end
    out.0 = n
    call stream f, 'C', 'CLOSE'
  end
  else do
    cmd = 'D TCPIP,'cstk',NETSTAT,'creport || cfg.maxopt
    if csys <> localsys then cmd = 'RO' csys','cmd
    /* replies arrive asynchronously: if the report end line is     */
    /* missing, try again once with a longer wait                   */
    do attempt = 1 to 2
      isfdelay = cfg.delay * attempt
      drop isfulog. isfmsg2.
      out.0 = 0
      address SDSF "ISFSLASH '"cmd"' (WAIT)"
      src = rc
      if symbol('ISFULOG.0') = 'VAR' then
        do i = 0 to isfulog.0
          out.i = isfulog.i
        end
      complete = 0
      do i = 1 to out.0
        u = translate(out.i)
        if pos('END OF THE REPORT', u) > 0 | ,
           pos('RECORDS DISPLAYED', u) > 0 | ,
           pos('IEE341I', u) > 0 then complete = 1
      end
      if complete then leave
    end
    if src <> 0 then do                 /* show SDSF's own reason    */
      m = 'SDSF ISFSLASH rc='src isfmsg
      if symbol('ISFMSG2.0') = 'VAR' then
        do i = 1 to isfmsg2.0
          m = m isfmsg2.i
        end
      call Note csys kind':' m
    end
    else if \complete & out.0 > 0 then
      call Note 'Reply from' csys 'for' kind 'looks incomplete' ,
                '(no end-of-report line) - increase cfg.delay.'
  end
  if q.debug = 1 then do              /* DEBUG: show raw replies    */
    say '----' csys kind 'reply:' out.0 'line(s)'
    do i = 1 to out.0
      say out.i
    end
  end
  if out.0 = 0 then do
    call Note 'No reply from' csys '(stack' cstk') - LPAR down, RO' ,
              'not authorized, or increase cfg.delay. Results do not' ,
              'include' csys'.'
    deadsys = deadsys csys
    return
  end
  /* stack not active / unknown proc name                           */
  do i = 1 to out.0
    u = translate(out.i)
    if pos('IEE341I', u) > 0 | pos('NOT ACTIVE', u) > 0 then do
      call Note 'TCP/IP stack' cstk 'is not active on' csys ,
                '(or the proc name differs - set stackname.'csys')'
      deadsys = deadsys csys
      return
    end
  end
  select
    when kind = 'ALLCONN'  then call ParseConns csys
    when kind = 'PORTLIST' then call ParsePortlist csys
    when kind = 'HOME'     then call ParseHome csys
    when kind = 'VIPADYN'  then call ParseVipadyn csys
    otherwise nop
  end
return
/* ================================================================= */
/* Parsers. These match on content, not column position, so the    */
/* ULOG prefix (system, time, jobid) does not matter.               */
/* ================================================================= */
ParseConns:
  parse arg psys
  tcpstates = 'LISTEN ESTBLSH SYNSENT SYNRCVD FINWAIT1 FINWAIT2' ,
              'CLOSWAIT LASTACK CLOSING TIMEWAIT CLOSED'
  cur = 0
  do i = 1 to out.0
    u = translate(out.i)
    if pos('LOCAL SOCKET:', u) > 0 then do
      if cur > 0 then do
        parse var u 'LOCAL SOCKET:' sk .
        call SplitSock sk
        conn.cur.lip = sock.ip; conn.cur.lport = sock.port
      end
      iterate
    end
    if pos('FOREIGN SOCKET:', u) > 0 then do
      if cur > 0 then do
        parse var u 'FOREIGN SOCKET:' sk .
        call SplitSock sk
        conn.cur.fip = sock.ip; conn.cur.fport = sock.port
        if \KeepConn(cur) then do      /* REXX-side filter         */
          conn.0 = conn.0 - 1
        end
        cur = 0
      end
      iterate
    end
    /* one-line format (console default):                          */
    /*   <user> <8-hex conn id> <local..port> <foreign..port> <state> */
    nw = words(u)
    hit1 = 0
    do k = 2 to nw - 3
      w = word(u, k)
      if length(w) = 8 & datatype(w, 'X') then
        if wordpos(word(u, k + 3), tcpstates) > 0 & ,
           pos('..', word(u, k + 1)) > 0 then do
          cur = conn.0 + 1
          conn.0 = cur
          conn.cur.sys   = psys
          conn.cur.user  = word(u, k - 1)
          conn.cur.id    = w
          conn.cur.state = word(u, k + 3)
          call SplitSock word(u, k + 1)
          conn.cur.lip = sock.ip; conn.cur.lport = sock.port
          call SplitSock word(u, k + 2)
          conn.cur.fip = sock.ip; conn.cur.fport = sock.port
          if \KeepConn(cur) then conn.0 = conn.0 - 1
          cur = 0                    /* no socket lines follow      */
          hit1 = 1
          leave
        end
    end
    if hit1 then iterate
    /* multi-line format: <user> <8-hex conn id> <state>            */
    /*   then LOCAL SOCKET: / FOREIGN SOCKET: lines                 */
    do k = 2 to nw - 1
      w = word(u, k)
      if length(w) = 8 & datatype(w, 'X') then
        if wordpos(word(u, k + 1), tcpstates) > 0 then do
          cur = conn.0 + 1
          conn.0 = cur
          conn.cur.sys   = psys
          conn.cur.user  = word(u, k - 1)
          conn.cur.id    = w
          conn.cur.state = word(u, k + 1)
          conn.cur.lip = ''; conn.cur.lport = ''
          conn.cur.fip = ''; conn.cur.fport = ''
          leave
        end
    end
  end
return
/* keep only connections relevant to the query                      */
KeepConn: procedure expose conn. q. ips.
  arg c
  select
    when q.type = 'PORT' then return conn.c.lport = q.value
    when q.type = 'JOB'  then return conn.c.user = q.value
    when q.type = 'ALL'  then return 1
    otherwise do                       /* IP / HOST                */
      hit = 0
      do i = 1 to ips.0
        if conn.c.lip = ips.i | conn.c.fip = ips.i then hit = 1
        /* a listener on all addresses (*) can serve this IP        */
        if conn.c.lip = '*' & conn.c.state = 'LISTEN' then hit = 1
      end
      if \hit then return 0
      if q.port <> '' then
        return conn.c.lport = q.port | conn.c.fport = q.port
      return 1
    end
  end
SplitSock: procedure expose sock.
  parse arg s
  s = strip(s)
  if left(translate(s), 7) = '::FFFF:' then s = substr(s, 8)
  p = lastpos('..', s)
  if p = 0 then do
    sock.ip = s; sock.port = ''
  end
  else do
    sock.ip = left(s, p - 1); sock.port = substr(s, p + 2)
  end
  if sock.ip = '0.0.0.0' | sock.ip = '::' then sock.ip = '*'
return
ParsePortlist:
  parse arg psys
  do i = 1 to out.0
    u = translate(out.i)
    nw = words(u)
    do k = 1 to nw - 2
      w = word(u, k)
      if datatype(w, 'W') & length(w) <= 5 then  /* 20 or 00020 */
        if wordpos(word(u, k + 1), 'TCP UDP') > 0 then do
          r = rsv.0 + 1
          rsv.0 = r
          rsv.r.sys   = psys
          rsv.r.port  = w + 0
          rsv.r.prot  = word(u, k + 1)
          rsv.r.user  = word(u, k + 2)
          rsv.r.flags = subword(u, k + 3)
          leave
        end
    end
  end
return
ParseHome:
  parse arg psys
  curif = ''
  do i = 1 to out.0
    u = translate(out.i)
    if pos('LINKNAME:', u) > 0 then parse var u 'LINKNAME:' curif .
    if pos('INTFNAME:', u) > 0 then parse var u 'INTFNAME:' curif .
    if pos('ADDRESS:', u) > 0 & pos('HOME ADDRESS', u) = 0 then do
      parse var u 'ADDRESS:' a .
      if a = '' then iterate
      h = home.0 + 1
      home.0 = h
      home.h.sys = psys; home.h.ip = a; home.h.intf = curif
    end
  end
return
ParseVipadyn:
  parse arg psys
  vstates = 'ACTIVE BACKUP MOVING QUIESCING QUIESCED UNAVAIL'
  cv = 0
  do i = 1 to out.0
    u = translate(out.i)
    /* short format: <ip> <mask> <status> <origin> [diststat]       */
    nw = words(u)
    hit = 0
    do k = 1 to nw - 2
      if ValidIp(word(u, k)) then
        if ValidIp(word(u, k + 1)) then
          if wordpos(word(u, k + 2), vstates) > 0 then do
            cv = vip.0 + 1
            vip.0 = cv
            vip.cv.sys = psys; vip.cv.ip = word(u, k)
            vip.cv.status = word(u, k + 2)
            vip.cv.origin = word(u, k + 3)
            hit = 1
            leave
          end
    end
    if hit then iterate
    /* long format: IPADDR/PREFIXLEN: ip/nn  then  STATUS: x ...    */
    if pos('IPADDR', u) > 0 & pos(':', u) > 0 then do
      parse var u 'IPADDR' . ':' a .
      parse var a a '/' .
      if \ValidIp(a) then iterate
      cv = vip.0 + 1
      vip.0 = cv
      vip.cv.sys = psys; vip.cv.ip = a; vip.cv.status = '?'
      vip.cv.origin = ''
    end
    if pos('STATUS:', u) > 0 & cv > 0 then do
      parse var u 'STATUS:' st .
      vip.cv.status = st
      if pos('ORIGIN:', u) > 0 then parse var u 'ORIGIN:' og .
      else og = ''
      vip.cv.origin = og
    end
  end
return
/* Is a job active on an LPAR?  Returns 1 / 0 / ? (unknown).        */
IsActive:
  parse upper arg aj, asys
  if act.aj.asys <> '?' then return act.aj.asys
  if actall then return 0           /* bulk list loaded: not active */
  if act.aj.checked = 1 then return 0
  act.aj.checked = 1
  if test then do
    f = testdir'/ACTIVE.txt'
    do while lines(f) > 0
      parse upper value linein(f) with j sy .
      if j = aj then act.aj.sy = 1
    end
    call stream f, 'C', 'CLOSE'
  end
  else do
    isfprefix = aj; isfowner = '*'; isfsysname = '*'
    isfcols = 'JNAME SYSNAME'
    address SDSF 'ISFEXEC DA'
    if rc <> 0 then do
      act.aj.checked = 0
      return '?'
    end
    do ai = 1 to jname.0
      if jname.ai = aj then do
        sy = sysname.ai
        act.aj.sy = 1
      end
    end
    isfprefix = ''; isfsysname = ''; isfcols = ''
  end
  if act.aj.asys = '?' then return 0
return act.aj.asys
/* Resolve a host name with the z/OS resolver (REXX sockets)         */
Resolve:
  parse arg hn
  ips.0 = 0
  if test then do
    f = testdir'/DNS.txt'
    do while lines(f) > 0
      parse upper value linein(f) with h rest
      if h = translate(hn) then
        do i = 1 to words(rest)
          n = ips.0 + 1; ips.n = word(rest, i); ips.0 = n
        end
    end
    call stream f, 'C', 'CLOSE'
  end
  else do
    r = socket('INITIALIZE', 'NETLOOK')
    if word(r, 1) = 0 then do
      r = socket('GETHOSTBYNAME', hn)
      if word(r, 1) = 0 then
        do i = 2 to words(r)
          n = ips.0 + 1; ips.n = word(r, i); ips.0 = n
        end
      call socket 'TERMINATE'
    end
  end
  if ips.0 = 0 then do
 call Find '!!', 'DNS cannot resolve' hn 'from z/OS.'
 call Cmd 'TSO HOMETEST', 'checks the z/OS resolver setup (TCPIP.DATA)'
 call Cmd 'TSO NSLOOKUP' hn, 'asks the name server for' hn
    call Step 'Check the spelling with the user. If correct, the z/OS' ,
              'resolver (TCPIP.DATA / name servers) has no entry -' ,
              'ask the DNS team, or use the IP address directly.'
  end
  else do
    l = ''
    do i = 1 to ips.0; l = l ips.i; end
    call Find '--', hn 'resolves to' strip(l)'.'
  end
return
/* ================================================================= */
/* Diagnosis                                                         */
/* ================================================================= */
/* ---- PORT ------------------------------------------------------- */
DiagPort:
  parse arg dp, dip            /* dip: restrict to IP (optional)    */
  drop lst.; lst. = 0
  nl = 0
  /* owner first: who is this port assigned to?                    */
  do r = 1 to rsv.0
    if rsv.r.port <> dp then iterate
    if rsv.r.user = 'RESERVED' then iterate
    call Find '--', 'Port' dp 'belongs to' rsv.r.user 'on' rsv.r.sys ,
              '(PORT statement in PROFILE.TCPIP).'
  end
  do c = 1 to conn.0
    if conn.c.state = 'LISTEN' & conn.c.lport = dp then do
      if dip <> '' & conn.c.lip <> '*' & conn.c.lip <> dip then iterate
      nl = nl + 1
      if conn.c.lip = '*' then where = 'all IP addresses'
      else where = 'IP' conn.c.lip 'only'
      call Find 'OK', 'Port' dp 'is LISTENING on' conn.c.sys ,
                'by' conn.c.user '('where').'
      call Cmd TC(conn.c.sys)'ALL,CLIENT='conn.c.user, 'listener' ,
               'detail: backlog, connections dropped'
      if conn.c.lip <> '*' & dip = '' then
        call Find '--', 'Clients must use' conn.c.lip':'dp ,
                  '- other IPs on' conn.c.sys 'will refuse this port.'
      ls = conn.c.sys
      lst.dp.ls = 1
    end
  end
  /* reservations                                                   */
  do r = 1 to rsv.0
    if rsv.r.port <> dp then iterate
    rs = rsv.r.sys; ru = rsv.r.user
    if lst.dp.rs then iterate                     /* listening, fine */
    /* listening elsewhere: this LPAR is likely a standby - info only */
    if nl > 0 then do
      if ru = 'RESERVED' | ru = '*' | ru = 'OMVS' then iterate
      if IsActive(ru, rs) = 1 then st2 = 'running but not listening'
      else st2 = 'not running'
      call Find '--', 'Port' dp 'is also reserved for' ru 'on' rs ,
                '('ru st2 'there - normal if' rs 'is a standby).'
      iterate
    end
    select
      when ru = 'RESERVED' then do
        call Find '!!', 'Port' dp 'is BLOCKED on' rs ,
                  '(PORT ... RESERVED in PROFILE.TCPIP).'
        call Cmd TC(rs)'PORTL', 'all PORT reservations on' rs
        call Step 'No application can use port' dp 'on' rs'. If it' ,
                  'should be open, change the PORT statement in' ,
                  'PROFILE.TCPIP and OBEYFILE it.'
      end
      when ru = '*' | ru = 'OMVS' then
        call Find '!!', 'Port' dp 'is reserved for' ru 'on' rs ,
                  'but nothing is listening on it.'
      otherwise do
        a = IsActive(ru, rs)
        if a = 1 then do
  call Find '!!', ru 'is RUNNING on' rs 'but is NOT listening' ,
                'on port' dp '(port is reserved for it).'
  call Cmd 'SDSF: PREFIX' ru '; DA ; ? on' ru, 'open' ru 'joblog -',
                'look for EDC8115I, ICH408I, BPX/EZA/EZZ errors'
      call Cmd TC(rs)'ALLC,CLIENT='ru, 'every socket' ru 'has open'
  call Cmd TC(rs)'SOCKETS,CLIENT='ru, 'TCP and UDP sockets of' ru
  call Step 'Check' ru'''s joblog on' rs 'for bind/listen' ,
                 'errors: "address in use", EZA/BPX/EDC messages,' ,
                'or a SAF denial on the port. Its own config may' ,
                'name a different port.'
        end
        else if a = 0 then do
          call Find '!!', ru 'is NOT RUNNING on' rs ,
                    '- port' dp 'is reserved for it.'
  call Cmd RO(rs)'D A,'ru, 'confirms whether' ru 'is active on' rs
  call Cmd 'SDSF: PREFIX' ru '; ST', 'last run of' ru '- check how it',
                   'ended (abend, cancel, RC)'
  call Step 'Start' ru 'on' rs '(or check why it ended),' ,
                    'then re-run NETLOOK.'
        end
        else
          call Find '!!', 'Port' dp 'is reserved for' ru 'on' rs ,
                    'but nothing is listening (could not check if' ,
                    ru 'is running).'
      end
    end
  end
  if nl = 0 then do
    hasrsv = 0
    do r = 1 to rsv.0
      if rsv.r.port = dp then hasrsv = 1
    end
    if \hasrsv then do
      call Find '!!', 'Nothing is listening on port' dp 'on any' ,
                'LPAR checked, and no PORT reservation exists.'
      call Cmd TC(localsys)'PORTL', 'all reserved ports - is the app' ,
               'maybe using a different port?'
      call Step 'Confirm the port number with the application team.' ,
                'If the app runs off the mainframe, the problem is' ,
                'not on z/OS.'
    end
  end
  call ConnSummary dp, dip
return
/* inbound connection summary + unhealthy states                    */
ConnSummary:
  parse arg sp, sip
  est = 0; drop bad.; bad. = 0
  do c = 1 to conn.0
    if conn.c.state = 'LISTEN' then iterate
    if sp <> '' & conn.c.lport <> sp & conn.c.fport <> sp then iterate
    if sip <> '' & conn.c.lip <> sip & conn.c.fip <> sip then iterate
    st = conn.c.state
    if st = 'ESTBLSH' then est = est + 1
    else bad.st = bad.st + 1
  end
  if est > 0 then
    call Find 'OK', est 'established connection(s) right now.'
  call StateAdvice
return
StateAdvice:
  if bad.SYNRCVD > 0 then do
    call Find '!!', bad.SYNRCVD 'connection(s) stuck in SYNRCVD' ,
              '(handshake not completing).'
    call Cmd 'TSO PING <client-ip>', 'can z/OS reach the client back?'
    call Cmd 'TSO TRACERTE <client-ip>', 'shows where the return path' ,
             'stops'
    call Cmd TC(localsys)'ROUTE', 'z/OS routing table'
    call Step 'Client reached z/OS but the final ACK never arrived:' ,
              'usually a firewall or one-way routing problem, or the' ,
              'listen backlog is full. Ask the network team to check' ,
              'the path back from z/OS to the client.'
  end
  if bad.SYNSENT > 0 then do
    call Find '!!', bad.SYNSENT 'outbound connection(s) in SYNSENT' ,
              '(remote side not answering).'
    call Cmd 'TSO PING <remote-ip>', 'is the remote host reachable?'
    call Cmd 'TSO TRACERTE <remote-ip>', 'where the path stops'
    call Step 'The remote host/port is down or blocked by a' ,
              'firewall. Test from the remote side, or ask the' ,
              'network team.'
  end
  if bad.CLOSWAIT > 0 then do
    call Find '!!', bad.CLOSWAIT 'connection(s) in CLOSWAIT' ,
              '(remote closed, application has not).'
    call Cmd 'SDSF: DA ; ? on the job', 'joblog - look for hung or' ,
             'error messages'
    call Step 'The application is not closing its sockets - it may' ,
              'be hung or leaking. Check the application; a recycle' ,
              'clears them.'
  end
  other = bad.FINWAIT1 + bad.FINWAIT2 + bad.TIMEWAIT + bad.LASTACK ,
        + bad.CLOSING
  if other > 0 then
    call Find '--', other 'connection(s) closing normally' ,
              '(FINWAIT/TIMEWAIT/LASTACK).'
return
/* ---- IP --------------------------------------------------------- */
DiagIp:
  parse arg di, dport
  owners = ''
  do h = 1 to home.0
    if home.h.ip = di then do
      owners = owners home.h.sys
      call Find 'OK', di 'is a home address on' home.h.sys ,
                '(interface' home.h.intf').'
    end
  end
  vact = ''; vother = ''
  do v = 1 to vip.0
    if vip.v.ip <> di then iterate
    if vip.v.status = 'ACTIVE' then vact = vact vip.v.sys
    else vother = vother vip.v.sys'('vip.v.status')'
  end
  if vact <> '' then
    call Find 'OK', di 'is a dynamic VIPA, ACTIVE on' strip(vact)'.'
  if vother <> '' & vact <> '' then
    call Find '--', 'VIPA' di 'also defined on' strip(vother)'.'
  if vact = '' & vother <> '' then do
    call Find '!!', 'VIPA' di 'is defined on' strip(vother) ,
              'but NOT ACTIVE on any LPAR - nothing can answer on it.'
    call Cmd TC(localsys)'VIPADYN', 'current VIPA state on every stack'
    call Cmd TC(localsys)'VIPADCFG', 'how the VIPA is configured'
    call Step 'Check that the owning TCP/IP stack is up and the' ,
              'VIPADEFINE/VIPABACKUP statements in PROFILE.TCPIP.' ,
              'D TCPIP,,NETSTAT,VIPADYN shows the current state.'
    if owners = '' then return
  end
  if owners = '' & vact = '' then do
    /* not ours: is it a client talking to us?                      */
    n = 0
    do c = 1 to conn.0
      if conn.c.fip <> di then iterate
      if dport <> '' & conn.c.lport <> dport & conn.c.fport <> dport ,
        then iterate
      n = n + 1
    end
    if n > 0 then do
      call Find '--', di 'is not a mainframe address. It is a remote' ,
                'host with' n 'connection(s) to the mainframe:'
      call ListPeers di, dport
      call ConnSummary dport, di
    end
    else do
      call Find '!!', di 'is not owned by any LPAR checked and has' ,
                'no connections to the mainframe right now.'
      call Cmd 'TSO PING' di, 'can z/OS reach' di'?'
      call Cmd 'TSO TRACERTE' di, 'where the path to' di 'stops'
      call Cmd TC(localsys)'HOME', 'all IP addresses this LPAR owns'
      call Step 'If' di 'is the USER''s address: their traffic is not' ,
                'reaching z/OS - check client config, firewall and' ,
                'routing.'
      call Step 'If' di 'should be a MAINFRAME address: it is not in' ,
                'any HOME list or VIPA - check PROFILE.TCPIP' ,
                '(HOME/VIPADYNAMIC) and the DNS entry.'
    end
    return
  end
  /* ours: what listens on it?                                       */
  if dport <> '' then do
    call DiagPort dport, di
    return
  end
  nl = 0
  do c = 1 to conn.0
    if conn.c.state <> 'LISTEN' then iterate
    if conn.c.lip <> di & conn.c.lip <> '*' then iterate
    if wordpos(conn.c.sys, owners vact) = 0 then iterate
    nl = nl + 1
  end
  if nl > 0 then
    call Find '--', nl 'listening port(s) reachable on' di ,
              '- see DETAILS. Ask the user which port fails, then' ,
              're-run with PORT(n).'
  else
    call Find '!!', 'Nothing is listening on' di'.'
  call ConnSummary '', di
return
/* For IP/HOST lookups, "listen on all IPs" sockets only matter on  */
/* the LPARs that own the address. Drop the rest.                   */
PruneListeners:
  own = ''
  do i = 1 to ips.0
    do h = 1 to home.0
      if home.h.ip = ips.i then own = own home.h.sys
    end
    do v = 1 to vip.0
 if vip.v.ip = ips.i & vip.v.status = 'ACTIVE' then own = own vip.v.sys
    end
  end
  n = 0
  do c = 1 to conn.0
    if conn.c.state = 'LISTEN' & conn.c.lip = '*' then
      if wordpos(conn.c.sys, own) = 0 then iterate
    n = n + 1
    if n = c then iterate
    conn.n.sys = conn.c.sys; conn.n.user = conn.c.user
    conn.n.id = conn.c.id; conn.n.state = conn.c.state
    conn.n.lip = conn.c.lip; conn.n.lport = conn.c.lport
    conn.n.fip = conn.c.fip; conn.n.fport = conn.c.fport
  end
  conn.0 = n
return
ListPeers:
  parse arg pip, pport
  drop seen.; seen. = 0
  do c = 1 to conn.0
    if conn.c.fip <> pip then iterate
    if pport <> '' & conn.c.lport <> pport & conn.c.fport <> pport ,
      then iterate
    key = conn.c.sys'/'conn.c.user'/'conn.c.lport'/'conn.c.state
    if seen.key then iterate
    seen.key = 1
    call Find '  ', '  ->' conn.c.user 'on' conn.c.sys 'port' ,
              conn.c.lport '('conn.c.state')'
  end
return
/* ---- ALL: health check of every reserved / listening port ----- */
DiagAll:
  call LoadAllActive
  drop lu. li. est. syn. clw. seenk.
  lu. = ''; li. = ''; est. = 0; syn. = 0; clw. = 0; seenk. = 0
  lstport. = 0                      /* port listening on any LPAR   */
  do c = 1 to conn.0
    k = conn.c.sys'/'conn.c.lport
    st = conn.c.state
    select
      when st = 'LISTEN' then do
        lu.k = conn.c.user
        li.k = conn.c.lip
        pp = conn.c.lport
        lstport.pp = 1
      end
      when st = 'ESTBLSH'  then est.k = est.k + 1
      when st = 'SYNRCVD'  then syn.k = syn.k + 1
      when st = 'CLOSWAIT' then clw.k = clw.k + 1
      otherwise nop
    end
  end
  nok = 0; nstby = 0; nblk = 0; nbad = 0; ninfo = 0
  /* 1. every PORT reservation                                      */
  do r = 1 to rsv.0
    if rsv.r.prot <> 'TCP' then iterate
    ys = rsv.r.sys; pp = rsv.r.port; ru = rsv.r.user
    k = ys'/'pp
    if seenk.k then iterate
    seenk.k = 1
    select
      when ru = 'RESERVED' then do
        stat = 'BLOCKED'; sev = '--'; nblk = nblk + 1
        why = 'Port closed on purpose (PORT RESERVED)'
      end
      when lu.k <> '' then do
        stat = 'OK'; sev = 'OK'; nok = nok + 1
        why = 'Listening' AllOrIp(li.k)
      end
      when ru = '*' | ru = 'OMVS' then do
        stat = 'NO LISTN'; sev = '--'; ninfo = ninfo + 1
        why = 'Reserved for' ru', nothing listening'
      end
      otherwise do
        a = IsActive(ru, ys)
        if a = 1 then do
          stat = 'NOT LSTN'; sev = '!!'; nbad = nbad + 1
          why = ru 'running but not listening'
           worst = 4               /* shown in PORT HEALTH table */
   call Cmd 'SDSF: PREFIX' ru '; DA ; ? on' ru, 'open' ru 'joblog -',
                   'look for EDC8115I, ICH408I, BPX/EZA/EZZ errors'
   call Cmd TC(ys)'ALLC,CLIENT='ru, 'every socket' ru 'has open'
  call Step 'For jobs RUNNING but NOT LISTENING: check the' ,
                    'joblog for bind errors ("address in use",' ,
                    'EZA/BPX/EDC messages, SAF denial on the port).'
        end
        else if lstport.pp then do
          stat = 'STANDBY'; sev = '--'; nstby = nstby + 1
          why = ru 'not running here; port is up on another LPAR'
        end
        else do
          stat = 'DOWN'; sev = '!!'; nbad = nbad + 1
          why = ru 'is not running'
 worst = 4                     /* shown in PORT HEALTH table */
 call Cmd 'SDSF: PREFIX' ru '; ST', 'last run of' ru '- check how it',
                   'ended (abend, cancel, RC)'
    call Step 'For jobs NOT RUNNING: start them (or confirm' ,
                    'they are retired and remove the PORT statement' ,
                    'from PROFILE.TCPIP).'
        end
      end
    end
    call AddHealth ys, pp, ru, stat, sev, k, why
  end
  /* 2. listeners with no reservation                               */
  do c = 1 to conn.0
    if conn.c.state <> 'LISTEN' then iterate
    k = conn.c.sys'/'conn.c.lport
    if seenk.k then iterate
    seenk.k = 1
    nok = nok + 1
    call AddHealth conn.c.sys, conn.c.lport, conn.c.user, 'OK', 'OK', ,
                   k, 'Listening' AllOrIp(li.k)', no PORT reservation'
  end
  /* summary (counted from the table, after connection checks)    */
  if ph.0 = 0 then do
    call Find '!!', 'No ports found. Check the NOTES below.'
    return
  end
  nbad = 0; nok = 0
  do i = 1 to ph.0
    if ph.i.5 = '!!' then nbad = nbad + 1
    if ph.i.5 = 'OK' then nok = nok + 1
  end
  drop bad.; bad. = 0
  do c = 1 to conn.0
    st = conn.c.state
    if st <> 'LISTEN' & st <> 'ESTBLSH' then bad.st = bad.st + 1
  end
  if nbad = 0 & bad.SYNRCVD + bad.SYNSENT + bad.CLOSWAIT = 0 then do
    call Find 'OK', 'ALL GOOD - every port checked is healthy.'
    call Find 'OK', nok 'port(s) listening normally on' sys.0 ,
              'LPAR(s).'
  end
  else do
    if nbad > 0 then
      call Find '!!', nbad 'port(s) need attention - marked [!!]' ,
                'at the top of the table.'
    call Find 'OK', nok 'port(s) listening normally.'
  end
  if nstby > 0 then
    call Find '--', nstby 'port(s) on standby LPARs (app runs' ,
              'elsewhere).'
  if nblk > 0 then
    call Find '--', nblk 'port(s) blocked on purpose (PORT RESERVED).'
  if ninfo > 0 then
    call Find '--', ninfo 'generic reservation(s) with nothing' ,
              'listening.'
  call StateAdvice
return
/* ---- Connection map: which port/STC is connected to what ------- */
ConnMap:
  drop gk. gseen. pk. pseen. pc. gl.
  gk.0 = 0; gseen. = 0; pseen. = 0; pc. = 0; gl. = ''
  do c = 1 to conn.0
    ys = conn.c.sys; st = conn.c.state
    k = ys'/'conn.c.lport
    if st = 'LISTEN' then do
      g = ys'/'conn.c.user'/L/'conn.c.lport
      call MapGroup g
      gl.g = AllOrIp(conn.c.lip)
      iterate
    end
    if st = 'CLOSED' then iterate
    if lu.k <> '' then do                    /* inbound to a listener */
      g = ys'/'lu.k'/L/'conn.c.lport
      call MapGroup g
      peer = '<-' conn.c.fip
    end
    else do                                  /* outbound from the job */
      g = ys'/'conn.c.user'/O/'
      call MapGroup g
      peer = '->' conn.c.fip':'conn.c.fport
    end
    pkey = g'|'peer'|'st
    if \pseen.pkey then do
      pseen.pkey = 1
      n = pk.g.0 + 0 + 1
      pk.g.0 = n; pk.g.n = peer'|'st
    end
    pc.pkey = pc.pkey + 1
  end
  call R ''
  call R 'CONNECTION MAP - which port / STC is connected to what'
  call R '  <- = remote client connected IN    -> = STC connecting OUT'
  if cfg.rdns & \test & onHost then call socket 'INITIALIZE', 'NETLOOKR'
  do i = 1 to gk.0
    g = gk.i
    parse var g ys '/' us '/' dir '/' pp
    call R ''
    if dir = 'L' then
      call R '  'left(ys, 8) left(us, 8) 'port' left(pp, 5) ,
             '(listening' gl.g')'
    else
      call R '  'left(ys, 8) left(us, 8) 'outbound connections'
    np = pk.g.0 + 0
    if np = 0 then call R '        (no connections right now)'
    do j = 1 to np
      parse var pk.g.j peer '|' st
      pkey = g'|'peer'|'st
      parse var peer arrow ipp
      parse var ipp pip ':' .
      nm = RevName(pip)
      line = '        'arrow left(ipp, 21) left(nm, 28) ,
             right(pc.pkey, 4) st
      call R strip(line, 'T')
    end
  end
  if cfg.rdns & \test & onHost then call socket 'TERMINATE', 'NETLOOKR'
return
MapGroup:
  parse arg mg
  if gseen.mg then return
  gseen.mg = 1
  n = gk.0 + 1; gk.0 = n; gk.n = mg
  pk.mg.0 = 0
return
/* Reverse DNS for a remote IP (cached). Blank if unknown.          */
RevName:
  parse arg rip
  if \cfg.rdns | rip = '*' | rip = '' then return ''
  if symbol('rdns.rip') = 'VAR' then return rdns.rip
  nmr = ''
  if test then do
    f = testdir'/DNS.txt'
    do while lines(f) > 0
      parse value linein(f) with h rest
      if wordpos(rip, rest) > 0 then nmr = h
    end
    call stream f, 'C', 'CLOSE'
  end
  else if onHost then do
    r = socket('GETHOSTBYADDR', rip)
    if word(r, 1) = 0 then nmr = word(r, 2)
  end
  rdns.rip = nmr
return nmr
AllOrIp:
  if arg(1) = '*' then return 'on all IPs'
return 'on' arg(1) 'only'
AddHealth:
  parse arg hs, hp, hu, hst, hsev, hk, hwhy
  if syn.hk > 0 then do
    hwhy = hwhy'; 'syn.hk 'stuck SYNRCVD'
    if hsev = 'OK' then do; hsev = '!!'; hst = 'WARN'; end
  end
  if clw.hk > 0 then do
    hwhy = hwhy'; 'clw.hk 'CLOSWAIT'
    if hsev = 'OK' then do; hsev = '!!'; hst = 'WARN'; end
  end
  n = ph.0 + 1; ph.0 = n
  ph.n.1 = hs; ph.n.2 = hp; ph.n.3 = hu; ph.n.4 = hst
  ph.n.5 = hsev; ph.n.6 = est.hk; ph.n.7 = hwhy
return
/* Load every active job on every LPAR with one SDSF DA call        */
LoadAllActive:
  if test then do
    f = testdir'/ACTIVE.txt'
    do while lines(f) > 0
      parse upper value linein(f) with j sy .
      if j <> '' then act.j.sy = 1
    end
    call stream f, 'C', 'CLOSE'
    actall = 1
    return
  end
  isfprefix = '*'; isfowner = '*'; isfsysname = '*'
  isfcols = 'JNAME SYSNAME'
  address SDSF 'ISFEXEC DA'
  if rc = 0 then do
    do ai = 1 to jname.0
      j = jname.ai; sy = sysname.ai
      act.j.sy = 1
    end
    actall = 1
  end
  isfprefix = ''; isfsysname = ''; isfcols = ''
return
HealthTable:
  call R ''
  call R 'PORT HEALTH - every reserved or listening TCP port'
  call R '     LPAR     PORT  JOB      STATUS   ESTAB  DETAIL'
  call R '     -------- ----- -------- -------- -----  ' ,
         || copies('-', 30)
  /* problems first, then the rest, each in collected order         */
  do pass = 1 to 2
    do i = 1 to ph.0
      if (pass = 1) <> (ph.i.5 = '!!') then iterate
      select
        when ph.i.5 = '!!' then tag = '[!!]'
        when ph.i.5 = 'OK' then tag = '[OK]'
        otherwise               tag = '[--]'
      end
      call Wrap 0, ' 'tag left(ph.i.1, 8) right(ph.i.2, 5) ,
                left(ph.i.3, 8) left(ph.i.4, 8) right(ph.i.6, 5)'  ', ,
                ph.i.7
    end
  end
return
/* ---- JOB -------------------------------------------------------- */
DiagJob:
  parse arg dj
  running = ''; unknown = 0
  do s = 1 to sys.0
    a = IsActive(dj, sys.s)
    if a = 1 then running = running sys.s
    if a = '?' then unknown = 1
  end
  if running <> '' then
    call Find 'OK', dj 'is running on' strip(running)'.'
  else if \unknown then do
    call Find '!!', dj 'is NOT running on any LPAR checked.'
    call Cmd 'SDSF: PREFIX' dj '; ST', 'last run of' dj ,
             '- check how it',
             'ended (abend, cancel, RC)'
    call Step 'Start' dj '(or find out why it ended), then re-run.'
  end
  /* listeners                                                       */
  drop lj.; lj. = 0
  nl = 0
  do c = 1 to conn.0
    if conn.c.user <> dj | conn.c.state <> 'LISTEN' then iterate
    nl = nl + 1
    if conn.c.lip = '*' then where = 'all IPs'
    else where = conn.c.lip
    call Find 'OK', 'Listening on port' conn.c.lport 'on' conn.c.sys ,
              '('where').'
    k = conn.c.sys'/'conn.c.lport
    lj.k = 1
  end
  /* reserved but not listening                                     */
  do r = 1 to rsv.0
    if rsv.r.user <> dj then iterate
    k = rsv.r.sys'/'rsv.r.port
    if lj.k then iterate
    if wordpos(rsv.r.sys, running) = 0 then iterate  /* not up there */
    call Find '!!', 'Port' rsv.r.port 'is reserved for' dj 'on' ,
              rsv.r.sys 'but' dj 'is NOT listening on it.'
    call Cmd 'SDSF: PREFIX' dj '; DA ; ? on' dj, 'open' dj 'joblog -' ,
             'look for EDC8115I, ICH408I, BPX/EZA/EZZ errors'
    call Cmd TC(rsv.r.sys)'SOCKETS,CLIENT='dj, ,
             'TCP and UDP sockets of' dj
    call Step 'Check' dj'''s joblog on' rsv.r.sys 'for bind errors' ,
              'on port' rsv.r.port', or confirm the port is still used.'
  end
  if nl = 0 & running <> '' then do
    nc = 0
    do c = 1 to conn.0
      if conn.c.user = dj then nc = nc + 1
    end
    if nc = 0 then
      call Find '--', dj 'has no TCP connections or listeners. If it' ,
                'should, check its network component started and it' ,
                'uses this TCP/IP stack.'
  end
  call ConnSummary '', ''
return
/* ---- Commands the user can run next (display only) ---------- */
Cmd: procedure expose cmdl.
  parse arg c, why
  do i = 1 to cmdl.0
    if cmdl.i.1 = c then return
  end
  n = cmdl.0 + 1; cmdl.0 = n
  cmdl.n.1 = c; cmdl.n.2 = why
return
/* console prefix: RO for another LPAR                             */
RO: procedure expose localsys
  parse arg rsys
  if rsys = '' | rsys = localsys then return '/'
return '/RO' rsys','
/* D TCPIP,<stack>,N,  for an LPAR                                 */
TC: procedure expose localsys stackname. q.
  parse arg tsys
  stk = stackname.tsys
  if q.stack <> '' then stk = q.stack
return RO(tsys)'D TCPIP,'stk',N,'
/* ================================================================= */
/* Report                                                            */
/* ================================================================= */
Find: procedure expose find. worst
  parse arg sev, txt
  n = find.0 + 1; find.0 = n
  find.n.1 = sev; find.n.2 = txt     /* numeric tails: no clash */
  if sev = '!!' then worst = 4
return
Step: procedure expose step.
  parse arg txt
  do i = 1 to step.0
    if step.i = txt then return      /* no duplicates               */
  end
  n = step.0 + 1; step.0 = n
  step.n = txt
return
Note: procedure expose note.
  parse arg txt
  do i = 1 to note.0
    if note.i = txt then return
  end
  n = note.0 + 1; note.0 = n
  note.n = txt
return
R: procedure expose rpt.
  parse arg line
  n = rpt.0 + 1; rpt.0 = n
  rpt.n = line
return
/* word-wrap with a hanging indent                                  */
Wrap: procedure expose rpt. cfg.
  parse arg ind, first, txt
  w = cfg.width - length(first)
  line = ''
  pre = first
  do i = 1 to words(txt)
    wd = word(txt, i)
    if line <> '' & length(line) + 1 + length(wd) > w then do
      call R pre || line
      pre = copies(' ', length(first))
      line = wd
    end
    else if line = '' then line = wd
    else line = line wd
  end
  if line <> '' then call R pre || line
return
BuildReport:
  bar = copies('=', cfg.width)
  sl = ''
  do i = 1 to sys.0; sl = sl sys.i; end
  qd = q.type q.value
  if q.port <> '' then qd = qd 'PORT' q.port
  call R 'NETLOOK' ver ' -  Mainframe network lookup' ,
         '      ' date('S') time()
  call R bar
  call R 'Query  :' qd
  call R 'Scope  :' sys.0 'LPAR(s):' strip(sl)
  if test then call R 'Mode   : TEST replay from' testdir
  call R bar
  call R ''
  call R 'FINDINGS'
  if find.0 = 0 then call R '  (none)'
  do i = 1 to find.0
    sev = find.i.1; txt = find.i.2
    select
      when sev = 'OK' then tag = '  [OK] '
      when sev = '!!' then tag = '  [!!] '
      when sev = '--' then tag = '  [--] '
      otherwise            tag = '       '
    end
    call Wrap 7, tag, txt
  end
   if 0 & step.0 > 0 then do            /* disabled: not wanted   */
    call R ''
    call R 'WHAT TO DO NEXT'
    do i = 1 to step.0
      call Wrap 6, right(i, 3)'.  ', step.i
    end
  end
   else if 0 then do                     /* disabled: not wanted   */
    call R ''
    call R 'WHAT TO DO NEXT'
    if deadsys <> '' then
      call Wrap 6, '  !   ', 'Could not check' strip(deadsys)'. If the',
                'application can run there, check it before trusting' ,
                'the result below (see NOTES).'
    call Wrap 6, '  1.  ', 'z/OS side looks healthy for this query.' ,
              'If the user still cannot connect, the issue is likely' ,
              'between the user and the mainframe (client config,' ,
              'firewall, VPN, DNS).'
  end
   if 0 & cmdl.0 > 0 then do            /* disabled: not wanted   */
    call R ''
    call R 'COMMANDS TO DIG FURTHER (display only - safe to run)'
  call R '  / = SDSF or console command    TSO = from READY / option 6'
    do i = 1 to cmdl.0
      call R ''
      call R '  'cmdl.i.1
      call Wrap 6, '      ', cmdl.i.2
    end
  end
  if q.type = 'ALL' then do
    call HealthTable
    call ConnMap
    signal BRnotes
  end
  /* details                                                        */
  call R ''
  call R 'DETAILS - TCP connections and listeners'
  if conn.0 = 0 then call R '  (none matched)'
  else do
    call R '  LPAR     JOB      STATE    LOCAL                 FOREIGN'
    call R '  -------- -------- -------- --------------------- ' ,
           || '---------------------'
    do c = 1 to conn.0
      lo = conn.c.lip':'conn.c.lport
      fo = conn.c.fip':'conn.c.fport
      if conn.c.state = 'LISTEN' then fo = '-'
      call R '  'left(conn.c.sys, 8) left(conn.c.user, 8) ,
             left(conn.c.state, 8) left(lo, 21) fo
    end
  end
  hdr = 0
  do r = 1 to rsv.0
    rel = 0
    if q.type = 'PORT' then rel = (rsv.r.port = q.value)
    if q.type = 'JOB'  then rel = (rsv.r.user = q.value)
    if q.port <> ''    then rel = (rsv.r.port = q.port)
    if \rel then iterate
    if \hdr then do
      call R ''
      call R 'RESERVED PORTS (PROFILE.TCPIP PORT statements)'
      call R '  LPAR     PORT  PROT JOB      FLAGS'
      hdr = 1
    end
    call R '  'left(rsv.r.sys, 8) right(rsv.r.port, 5) ,
           left(rsv.r.prot, 4) left(rsv.r.user, 8) rsv.r.flags
  end
  if home.0 + vip.0 > 0 then do
    hit = 0
    do h = 1 to home.0
      do i = 1 to ips.0
        if home.h.ip = ips.i then hit = 1
      end
    end
    do v = 1 to vip.0
      do i = 1 to ips.0
        if vip.v.ip = ips.i then hit = 1
      end
    end
    if hit then do
      call R ''
      call R 'IP OWNERSHIP'
      do h = 1 to home.0
        do i = 1 to ips.0
          if home.h.ip = ips.i then
            call R '  'left(home.h.sys, 8) left(home.h.ip, 16) ,
                   'HOME   interface' home.h.intf
        end
      end
      do v = 1 to vip.0
        do i = 1 to ips.0
          if vip.v.ip = ips.i then
            call R '  'left(vip.v.sys, 8) left(vip.v.ip, 16) ,
                   'VIPA  ' vip.v.status vip.v.origin
        end
      end
    end
  end
BRnotes:
  if note.0 > 0 then do
    call R ''
    call R 'NOTES'
    do i = 1 to note.0
      call Wrap 4, '  - ', note.i
    end
  end
  call R ''
  call R 'NETLOOK only issues DISPLAY commands. Nothing was changed.'
return
ShowReport:
  ispf = 0
  if onHost & \test then ispf = (sysvar('SYSISPF') = 'ACTIVE')
  if ispf then do
    dsn = cfg.rptdsn
    if dsn = '' then dsn = userid()'.NETLOOK.REPORT'
    if sysdsn("'"dsn"'") = 'OK' then
      call bpxwdyn "ALLOC FI(NLRPT) DA('"dsn"') OLD REUSE"
    else
      call bpxwdyn "ALLOC FI(NLRPT) DA('"dsn"') NEW CATALOG" ,
                   "RECFM(F,B) LRECL(133) TRACKS SPACE(5,5) REUSE"
    if result = 0 then do
      address mvs 'EXECIO' rpt.0 'DISKW NLRPT (STEM RPT. FINIS'
      call bpxwdyn 'FREE FI(NLRPT)'
      address ispexec "VIEW DATASET('"dsn"')"
      return
    end
  end
  do i = 1 to rpt.0
    say rpt.i
  end
return
/* SDSF REXX housekeeping                                           */
rxSdsfOn:
  rc = isfcalls('ON')
  if rc <> 0 then do
    say 'NETLOOK: SDSF REXX not available (ISFCALLS rc='rc').'
    exit 12
  end
return
rxSdsfOff2:
  call isfcalls 'OFF'
return
/* Command reference shown by option 3 - edit freely, keep markers
NETCMDS-START
************************************************************************
*  NETCMDS - TCP/IP and VTAM DISPLAY command reference (NETLOOK)
*
*  Every command here only DISPLAYS. Nothing is changed.
*  Replace <...> with your values:
*    <stk>  TCP/IP stack proc name       <job>  job / STC name
*    <port> port number                  <ip>   IP address
*    <tn>   TN3270 server proc name      <lu>   LU / applid name
*  Console / SDSF:  type with a leading /  (e.g. /D TCPIP)
*  Other LPAR:      /RO <lpar>,D TCPIP,...
************************************************************************
========================================================================
 1. STACK AND INTERFACES - is TCP/IP up, are the links up?
========================================================================
 D TCPIP                          List active TCP/IP stacks
 D TCPIP,<stk>,N,HOME             IP addresses this LPAR owns
 D TCPIP,<stk>,N,DEVLINKS         Interfaces/links and their status
 D TCPIP,<stk>,N,CONFIG           Stack configuration settings
 D TCPIP,<stk>,N,STATS            Stack-wide TCP/UDP/IP counters
 D OMVS,PFS                       INET or CINET (one or more stacks)
 D NET,TRL                        OSA/TRLE status (VTAM side of OSA)
 D NET,TRL,TRLE=<trle>            One OSA TRLE in detail
========================================================================
 2. PORTS AND CONNECTIONS - who listens, who is connected?
========================================================================
 D TCPIP,<stk>,N,PORTL            PORT reservations (PROFILE.TCPIP)
 D TCPIP,<stk>,N,ALLC             All connections incl. listeners
 D TCPIP,<stk>,N,CONN             Active connections only
 D TCPIP,<stk>,N,ALLC,CLIENT=<job>   Connections of one job
 D TCPIP,<stk>,N,SOCKETS,CLIENT=<job> TCP and UDP sockets of a job
 D TCPIP,<stk>,N,ALL,CLIENT=<job> Detail: backlog, connections
                                  dropped, bytes in/out
 D TCPIP,<stk>,N,BYTEINFO         Bytes sent/received per connection
 Connection states that mean trouble:
   SYNRCVD   client reached z/OS, handshake never completed
             (firewall / return route / backlog full)
   SYNSENT   z/OS calling out, remote not answering
   CLOSWAIT  remote closed, application did not (hung or leaking)
========================================================================
 3. IP ADDRESSES, VIPA AND ROUTING - where does traffic go?
========================================================================
 D TCPIP,<stk>,N,VIPADYN          Dynamic VIPAs: ACTIVE / BACKUP
 D TCPIP,<stk>,N,VIPADCFG         How VIPAs are defined
 D TCPIP,<stk>,SYSPLEX,VIPADYN    VIPA view across the sysplex
 D TCPIP,<stk>,N,VDPT             Sysplex distributor targets
 D TCPIP,<stk>,N,ROUTE            Routing table
 D TCPIP,<stk>,N,ARP              ARP cache (IP to MAC)
========================================================================
 4. TN3270 - user cannot get a 3270 session
========================================================================
 D TCPIP,<tn>,TELNET,PROFILE      TN3270 server settings
 D TCPIP,<tn>,TELNET,CONN         TN3270 connections and their LUs
 D NET,ID=<lu>,E                  Status of the LU or applid
 D NET,SESSIONS,LU1=<lu>          Sessions of an LU
========================================================================
 5. SECURITY / TLS - port denied, TLS handshake failing
========================================================================
 D TCPIP,<stk>,N,TTLS             AT-TLS connections and policies
 TSO PASEARCH -t                  AT-TLS policy as the stack sees it
 Joblog / SYSLOG messages to look for:
   ICH408I     RACF denied the job (often EZB.PORTACCESS.*)
   EDC8115I    Address already in use (port taken)
   EZD1287I    AT-TLS handshake failure
   EZZ4341I    Interface / link went down
========================================================================
 6. REACHABILITY AND DNS - from READY or ISPF option 6
========================================================================
 TSO PING <ip>                    Can z/OS reach the IP?
 TSO TRACERTE <ip>                Where does the path stop?
 TSO HOMETEST                     Resolver setup check (TCPIP.DATA)
 TSO NSLOOKUP <name>              Ask DNS for a name
 TSO NETSTAT HOME                 Same as N,HOME, from TSO
 TSO NETSTAT ALLCONN              Same as N,ALLC, from TSO
========================================================================
 7. VTAM - applications, LUs, Enterprise Extender
========================================================================
 D NET,VTAMOPTS                   VTAM start options
 D NET,MAJNODES                   Active major nodes
 D NET,APPLS                      All applications and status
 D NET,ID=<lu>,E                  One resource in detail + sessions
 D NET,INACT                      Inactive resources
 D NET,PENDING                    Resources stuck in a pending state
 D NET,EE                         Enterprise Extender summary
 D NET,BFRUSE                     VTAM buffer usage
========================================================================
 NOT display commands - do NOT use for checking:
   V TCPIP,,OBEYFILE   V TCPIP,,DROP   V TCPIP,,STOP/START
   V NET,ACT / INACT   P / S / F of stacks or applications
========================================================================
NETCMDS-END
*/
