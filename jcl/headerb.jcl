//BSCPOCB  JOB (POC),'BSC LINE POC - BTAM',CLASS=A,MSGCLASS=X,
//             MSGLEVEL=(1,1),REGION=1024K
//*
//* ------------------------------------------------------------------
//*  ASSEMBLE, LINK-EDIT AND RUN THE BTAM VERSION.
//*
//*  ASSEMBLE IT FIRST AND READ THE DIAGNOSTICS BEFORE LETTING THE GO
//*  STEP RUN - THE FOUR ITEMS MARKED >>> ASSUMPTION <<< IN THE SOURCE
//*  ARE THE ONES TO WATCH.  START tools/bscpartner.py BEFORE OR JUST
//*  AFTER SUBMITTING.  UNIT=090 IS THE VERIFIED LINE ADDRESS.
//* ------------------------------------------------------------------
//ASM      EXEC ASMFCLG,PARM.ASM='NODECK,LOAD',
//             PARM.LKED='LIST,MAP,LET'
//ASM.SYSIN DD *
