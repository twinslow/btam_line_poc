//TONYWCTL JOB (POC),'DEFINE CONTROL FILE',
//     CLASS=A,MSGCLASS=X,COND=(0,LT),NOTIFY=TONYW
//*
//* ------------------------------------------------------------------
//*  DEFINE AND LOAD THE VSAM KSDS CONTROL FILE FOR THE BSC FETCH
//*  APPLICATION.
//*
//*    KEY     30 BYTES, OFFSET 0   - THE FILE ID REQUESTED FROM THE
//*                                   REMOTE PARTNER
//*    RECORD  60 BYTES TOTAL
//*      +0   CL30  KEY
//*      +30  CL1   STATUS  I=IN PROGRESS  C=COMPLETE  D=DELETED
//*      +31  CL29  RESERVED
//*
//*  >>> PREREQUISITE <<<  THE VSAM CATALOG MUST ALREADY OWN THE
//*  VOLUME NAMED BELOW, OR THIS FAILS WITH
//*      IDC3033I VOLUME RECORD NOT FOUND IN CATALOG
//*  ON MVS 3.8 A CLUSTER IS SUBALLOCATED FROM A VSAM DATA SPACE ON A
//*  VOLUME THE CATALOG OWNS.  RUN jcl/VSAMCHK.jcl TO SEE WHICH
//*  VOLUMES ARE OWNED; IF NONE IS USABLE, RUN jcl/DEFSPACE.jcl FIRST.
//*
//*  >>> CHECK THE VOLUME <<<  VOLUMES(PUB000) BELOW IS A GUESS.  USE
//*  A VOLUME THAT ACTUALLY EXISTS AND HAS SPACE - "D U,DASD,ONLINE"
//*  AT THE MVS CONSOLE WILL LIST THEM.
//* ------------------------------------------------------------------
//*
//DEFINE   EXEC PGM=IDCAMS
//SYSPRINT DD  SYSOUT=*
//SYSIN    DD  *
  DELETE 'TONYW.BSCFTCH.CONTROL' CL

  DEFINE CLUSTER                                 -
         (NAME(TONYW.BSCFTCH.CONTROL)            -
          INDEXED                                -
          KEYS(30 0)                             -
          RECORDSIZE(60 60)                      -
          VOLUMES(TSO003)                        -
          CYLINDERS(1 1)                         -
          SHAREOPTIONS(4 3))                     -
         DATA                                    -
         (NAME(TONYW.BSCFTCH.CONTROL.DATA))      -
         INDEX                                   -
         (NAME(TONYW.BSCFTCH.CONTROL.INDEX))
/*
//*
//* ------------------------------------------------------------------
//*  THE SAMPLE RECORDS ARE PUNCHED AS 80 BYTE CARDS, SO IEBGENER
//*  TRIMS THEM TO THE 60 BYTES THE CLUSTER EXPECTS BEFORE REPRO
//*  LOADS THEM.  COLUMNS 1-30 KEY, 31 STATUS, 32-60 RESERVED.
//* ------------------------------------------------------------------
//TRIM     EXEC PGM=IEBGENER
//SYSPRINT DD  SYSOUT=*
//SYSUT2   DD  DSN=&&SEQIN,DISP=(,PASS),UNIT=SYSDA,
//             SPACE=(TRK,(1,1)),
//             DCB=(RECFM=FB,LRECL=60,BLKSIZE=600)
//SYSIN    DD  *
  GENERATE MAXFLDS=1
  RECORD   FIELD=(60,1,,1)
/*
//SYSUT1   DD  *              RECORDS BELOW ARE PRE-SORTED
ALREADY.DONE                  C
DAILY.LOG                     I
NOSUCH.TXT                    I
REPORT.TXT                    I
/*
//*
//LOAD     EXEC PGM=IDCAMS
//SYSPRINT DD  SYSOUT=*
//SEQIN    DD  DSN=&&SEQIN,DISP=(OLD,DELETE)
//SYSIN    DD  *
  REPRO INFILE(SEQIN) OUTDATASET(TONYW.BSCFTCH.CONTROL)
  PRINT INDATASET(TONYW.BSCFTCH.CONTROL) CHARACTER
/*
//
