//TONYWCTL JOB (POC),'DEFINE CONTROL FILE',
//     CLASS=A,MSGCLASS=X,COND=(0,LT),NOTIFY=TONYW
//*
//* ------------------------------------------------------------------
//*  UPDATE THE CONTROL DATASET RECORDS
//*
//*    KEY     30 BYTES, OFFSET 0   - THE FILE ID REQUESTED FROM THE
//*                                   REMOTE PARTNER
//*    RECORD  60 BYTES TOTAL
//*      +0   CL30  KEY
//*      +30  CL1   STATUS  I=IN PROGRESS  C=COMPLETE  D=DELETED
//*      +31  CL29  RESERVED
//*
//* ------------------------------------------------------------------
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
//SYSUT1   DD  *    RECORDS TO BE UPDATED (they must be presorted)
NEW001.TXT                    I
NOSUCH.TXT                    C
REPORT.TXT                    C
/*
//*
//LOAD     EXEC PGM=IDCAMS
//SYSPRINT DD  SYSOUT=*
//SEQIN    DD  DSN=&&SEQIN,DISP=(OLD,DELETE)
//CONTROL  DD  DISP=SHR,DSN=TONYW.BSCFTCH.CONTROL
//SYSIN    DD  *
  REPRO INFILE(SEQIN) OUTFILE(CONTROL) REPLACE
/*
//
