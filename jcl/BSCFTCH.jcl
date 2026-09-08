//BSCFTCH  JOB (POC),'BUILD BSCFTCH STC',CLASS=A,MSGCLASS=X,
//             MSGLEVEL=(1,1),REGION=1024K
//*
//* ------------------------------------------------------------------
//*  ASSEMBLE AND LINK THE BSC FETCH STARTED TASK INTO A LOAD LIBRARY.
//*  THIS IS STAGE 1 - THE SHELL.  SEE DOCS/FETCH-DESIGN.MD.
//*
//*  MAC1 ADDS SYS1.AMODGEN FOR IEZCOM AND IEZCIB, WHICH ARE NOT IN
//*  SYS1.MACLIB.
//*
//*  TO RUN IT:
//*    1. COPY PROCLIB/BSCFTCH.PROC INTO SYS1.PROCLIB AS MEMBER BSCFTCH
//*    2. START THE PARTNER ON THE LINUX SIDE.  GIVE IT BOTH ROUTES -
//*       IT TAKES WHICHEVER CONNECTS FIRST.  NEITHER IS RELIABLE ON
//*       ITS OWN: commadpt CALLS OUT WHEN BTAM ENABLES THE LINE, BUT
//*       BTAM DOES NOT ALWAYS ISSUE AN ENABLE; AND DIALLING IN IS
//*       REFUSED WHILE THE LINE IS NOT ENABLED.  --host/--port IS
//*       lport ON THE ATTACH, --listen IS rport:
//*         python tools/fetchpartner.py --host 192.168.1.168
//*                --port 3781 --listen 13781 --fdir ./files
//*    3. AT THE MVS CONSOLE:   S BSCFTCH
//*    4. TO STOP IT:           P BSCFTCH
//* ------------------------------------------------------------------
//ASM      EXEC ASMFCL,PARM.ASM='NODECK,LOAD',
//             MAC1='SYS1.AMODGEN',
//             PARM.LKED='LIST,MAP,LET,RENT'
//ASM.SYSIN DD *
