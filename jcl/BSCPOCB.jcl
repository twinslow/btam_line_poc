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
*---------------------------------------------------------------------*
*                                                                     *
*   B S C P O C B  -  THE BSC PROOF OF CONCEPT , DONE WITH BTAM       *
*                                                                     *
*   TARGET   : MVS 3.8J , OS/VS ASSEMBLER F  (ASMF)                   *
*   DEVICE   : IBM 2703 BSC LINE , POINT TO POINT NON SWITCHED ,      *
*              EMULATED BY HERCULES AND MAPPED ONTO A TCP SOCKET.     *
*                                                                     *
*   THIS IS THE SAME CONVERSATION AS BSCPOC , BUT BTAM RUNS THE LINE  *
*   DISCIPLINE INSTEAD OF US.  THERE ARE NO CCWS , NO IOB , AND NO    *
*   HAND CODED ENQ / ACK0 / ACK1 SEQUENCING HERE.                     *
*                                                                     *
*     1. OPEN THE LINE GROUP DCB   (DDNAME BSCLINE)                   *
*     2. WRITE TI  - BID FOR THE LINE AND SEND ONE BLOCK              *
*     3. WRITE TR  - END OUR TRANSMISSION                             *
*     4. READ  TI  - TAKE THE PARTNERS BID AND ONE BLOCK              *
*     5. READ  TT  - PICK UP THE PARTNERS END OF TRANSMISSION         *
*     6. CLOSE                                                        *
*                                                                     *
*   THE MACRO SYNTAX USED HERE WAS ESTABLISHED BY ASSEMBLING PROBE    *
*   DECKS ON THIS SYSTEM AND BY READING DFTRMLST AND TWAIT OUT OF     *
*   SYS1.MACLIB - SEE DOCS/BTAM-NOTES.MD.  THE OPERAND ORDER ON       *
*   READ / WRITE IS                                                   *
*                                                                     *
*        DECB , TYPE , DCB , AREA , LENGTH , TERMLIST , LINENO        *
*                                                                     *
*   T H I S   P R O G R A M   W O R K S .  IT HAS BEEN RUN AGAINST   *
*   THE 0090 LINE AND COMPLETED A FULL CONVERSATION IN BOTH           *
*   DIRECTIONS.  THAT RUN ALSO CONFIRMED THREE THINGS THAT WERE       *
*   ASSUMPTIONS WHEN IT WAS WRITTEN - SEE THE NOTES AT EACH STEP.     *
*                                                                     *
*   RETURN CODE  0 = OK / 8 = BTAM POSTED AN ERROR / 12 = OPEN FAILED *
*                                                                     *
*---------------------------------------------------------------------*
         PRINT NOGEN
         SPACE 1
*   ABSOLUTE SYMBOLS UP FRONT - ASSEMBLER F RESOLVES USING AND
*   EXPLICIT LENGTH FIELDS ON THE FIRST PASS.
R0       EQU   0
R1       EQU   1
R2       EQU   2
R3       EQU   3
R4       EQU   4
R5       EQU   5
R6       EQU   6
R7       EQU   7
R8       EQU   8
R9       EQU   9
R10      EQU   10
R11      EQU   11
R12      EQU   12
R13      EQU   13
R14      EQU   14
R15      EQU   15
         SPACE 1
STX      EQU   X'02'
ETX      EQU   X'03'
         SPACE 1
INLEN    EQU   256                 SIZE OF THE INPUT AREA
HEXMAX   EQU   23                  BYTES SHOWN BY THE HEX DUMP
HEXLEN   EQU   46                  ... WHICH IS 46 PRINT POSITIONS
TXTMAX   EQU   46                  TEXT CHARACTERS SHOWN BY A WTO
NORMAL   EQU   X'7F'               ECB POST CODE FOR NORMAL COMPLETION
         EJECT
BSCPOCB  CSECT
         STM   R14,R12,12(R13)     SAVE CALLERS REGISTERS
         LR    R12,R15             LOAD OUR BASE
         USING BSCPOCB,R12
         LA    R2,SAVEAREA
         ST    R13,4(R2)           BACKWARD CHAIN
         ST    R2,8(R13)           FORWARD CHAIN
         LR    R13,R2
         MVI   RETCODE,X'00'
         SPACE 1
*---------------------------------------------------------------------*
*   OPEN THE LINE GROUP.  THIS IS ALSO THE REAL TEST OF WHETHER THE   *
*   BTAM MODULES ARE INSTALLED - THE MACROS BEING IN SYS1.MACLIB DOES *
*   NOT PROVE IT.  IF OPEN FAILS , LOOK FOR AN IEC MESSAGE.           *
*---------------------------------------------------------------------*
         LA    R1,MSG010
         BAL   R14,SAY
         OPEN  (LINEDCB,(INPUT))
         TM    LINEDCB+48,X'10'    DCBOFLGS - DID THE OPEN WORK ?
         BO    OPENOK
         LA    R1,MSG012
         BAL   R14,SAY
         MVI   RETCODE,X'0C'
         B     RETURN
OPENOK   EQU   *
         LA    R1,MSG015
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 1 - WRITE INITIAL.                                           *
*                                                                     *
*   CONFIRMED BY A REAL RUN - WRITE TI PERFORMS THE WHOLE BID.  THE  *
*   PARTNER SAW ENQ , ANSWERED ACK0 , THEN RECEIVED THE TEXT BLOCK    *
*   AND ANSWERED ACK1 , ALL FROM THIS ONE MACRO.                      *
*                                                                     *
*   ALSO CONFIRMED - THE MESSAGE AREA CARRIES ITS OWN STX AND ETX.    *
*   BTAM DOES NOT FRAME THE BLOCK ; THE PARTNER SAW EXACTLY ONE STX.  *
*---------------------------------------------------------------------*
         LA    R1,MSG030
         BAL   R14,SAY
         MVC   TXTDATA,MSGSEND
         WRITE WDECB,TI,LINEDCB,TXTAREA,TXTLEN,TRMLST,1
         TWAIT (R2),ECBLIST=WECBL
         CLI   WDECB,NORMAL
         BE    WRITEOK
         LA    R1,MSG032
         BAL   R14,SAY
         LA    R1,WDECB
         BAL   R14,SHOWDECB
         B     BADIO
WRITEOK  EQU   *
         LA    R1,MSG034
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 2 - WRITE RESET.  THIS IS THE EOT THAT ENDS OUR TURN.        *
*   THE AREA AND LENGTH ARE NOT MEANINGFUL BUT THE MACRO WANTS THEM.  *
*---------------------------------------------------------------------*
         WRITE EDECB,TR,LINEDCB,TXTAREA,1,TRMLST,1
         TWAIT (R2),ECBLIST=EECBL
         CLI   EDECB,NORMAL
         BE    RESETOK
         LA    R1,MSG042
         BAL   R14,SAY
         LA    R1,EDECB
         BAL   R14,SHOWDECB
         B     BADIO
RESETOK  EQU   *
         LA    R1,MSG044
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 3 - READ INITIAL.  WE NOW WAIT FOR THE PARTNER TO BID AND    *
*   SEND US A BLOCK.  BTAM ANSWERS THE ENQ WITH ACK0 AND ACKS THE     *
*   BLOCK ITSELF.                                                     *
*---------------------------------------------------------------------*
         LA    R1,MSG050
         BAL   R14,SAY
         READ  RDECB,TI,LINEDCB,INAREA,INLEN,TRMLST,1
         TWAIT (R2),ECBLIST=RECBL
         CLI   RDECB,NORMAL
         BE    READOK
         LA    R1,MSG052
         BAL   R14,SAY
         LA    R1,RDECB
         BAL   R14,SHOWDECB
         B     BADIO
READOK   EQU   *
         LA    R1,MSG054
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   SHOW THE DECB IN HEX AS WELL AS THE DATA.                         *
*                                                                     *
*   STILL OPEN - WHERE BTAM POSTS THE RECEIVED LENGTH.  THE DECB IS  *
*   DUMPED SO IT CAN BE FOUND ; COMPARE IT WITH THE LENGTH FIELD AT   *
*   DECB+6 AND WITH WHAT THE PARTNER SENT.  NOT NEEDED FOR THIS       *
*   PROGRAM , WHICH SCANS FOR THE ETX INSTEAD.                        *
*---------------------------------------------------------------------*
         LA    R1,RDECB
         BAL   R14,SHOWDECB
         LA    R1,INAREA
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
         LA    R1,INAREA
         LA    R0,INLEN
         BAL   R14,SHOWTXT
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 4 - READ CONTINUE , TO PICK UP THE PARTNERS EOT.  A NON      *
*   NORMAL POST HERE IS NOT TREATED AS FATAL , BECAUSE BTAM MAY WELL  *
*   REPORT END OF TRANSMISSION WITH A CODE OF ITS OWN.                *
*---------------------------------------------------------------------*
         READ  TDECB,TT,LINEDCB,INAREA,INLEN,TRMLST,1
         TWAIT (R2),ECBLIST=TECBL
         CLI   TDECB,NORMAL
         BE    EOTOK
         LA    R1,MSG062
         BAL   R14,SAY
         LA    R1,TDECB
         BAL   R14,SHOWDECB
         B     FINISH
EOTOK    EQU   *
         LA    R1,MSG064
         BAL   R14,SAY
         B     FINISH
         SPACE 1
BADIO    LA    R1,MSG992
         BAL   R14,SAY
         MVI   RETCODE,X'08'
         SPACE 1
FINISH   EQU   *
         CLOSE (LINEDCB)
         LA    R1,MSG999
         BAL   R14,SAY
RETURN   EQU   *
         SR    R15,R15
         IC    R15,RETCODE
         L     R13,4(R13)
         ST    R15,16(R13)         RETURN CODE INTO CALLERS SAVE AREA
         LM    R14,R12,12(R13)
         BR    R14
         EJECT
*---------------------------------------------------------------------*
*   S H O W D E C B  -  WTO THE FIRST 8 BYTES OF A DECB IN HEX        *
*   ECB / FLAGS / TYPE / LENGTH.  ENTRY R1 = DECB ADDRESS.            *
*---------------------------------------------------------------------*
SHOWDECB ST    R14,DCBSAVE
         LA    R0,8
         BAL   R14,DUMPHEX
         L     R14,DCBSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   S H O W T X T  -  WTO THE TEXT OF AN INBOUND BLOCK                *
*   ENTRY R1 = BUFFER ADDRESS , R0 = BUFFER LENGTH.  LEADING STX IS   *
*   STEPPED OVER IF PRESENT , AND THE SCAN STOPS AT ETX.              *
*---------------------------------------------------------------------*
SHOWTXT  ST    R14,SHWSAVE
         MVC   MSGTEXT,MSGTXTP
         LR    R6,R1
         LR    R7,R0
         CLI   0(R6),STX           DID THE BLOCK KEEP ITS STX ?
         BNE   SHWSCAN0
         LA    R6,1(R6)
         BCTR  R7,0
SHWSCAN0 LTR   R7,R7
         BNP   SHWOUT
         LR    R8,R6
         LR    R9,R7
         SR    R5,R5
SHWSCAN  CLI   0(R8),ETX
         BE    SHWFND
         LA    R8,1(R8)
         LA    R5,1(R5)
         BCT   R9,SHWSCAN
SHWFND   LR    R7,R5
         LTR   R7,R7
         BNP   SHWOUT
         LA    R9,TXTMAX
         CR    R7,R9
         BNH   SHWMOVE
         LR    R7,R9               TRUNCATE TO WHAT FITS IN A WTO
SHWMOVE  BCTR  R7,0
         EX    R7,SHWMVC
SHWOUT   WTO   MF=(E,MSGWTO)
         L     R14,SHWSAVE
         BR    R14
SHWMVC   MVC   MSGTEXT+16(1),0(R6)      EXECUTED , LENGTH FROM R7
         SPACE 2
*---------------------------------------------------------------------*
*   D U M P H E X  -  WTO A HEX DUMP OF UP TO 23 BYTES                *
*   ENTRY R1 = ADDRESS , R0 = LENGTH                                  *
*---------------------------------------------------------------------*
DUMPHEX  ST    R14,DMPSAVE
         MVC   HEXOUT,BLANKS
         LR    R6,R1
         LR    R7,R0
         LA    R8,HEXOUT
         LTR   R7,R7
         BNP   DMPSHOW
         LA    R9,HEXMAX
         CR    R7,R9
         BNH   DMPLOOP
         LR    R7,R9
DMPLOOP  SR    R9,R9
         IC    R9,0(R6)
         SRL   R9,4
         LA    R9,HEXTAB(R9)
         MVC   0(1,R8),0(R9)
         SR    R9,R9
         IC    R9,0(R6)
         N     R9,F15
         LA    R9,HEXTAB(R9)
         MVC   1(1,R8),0(R9)
         LA    R6,1(R6)
         LA    R8,2(R8)
         BCT   R7,DMPLOOP
DMPSHOW  MVC   MSGTEXT,MSGHEX
         MVC   MSGTEXT+16(HEXLEN),HEXOUT
         WTO   MF=(E,MSGWTO)
         L     R14,DMPSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   S A Y  -  WTO THE 62 BYTE MESSAGE POINTED TO BY R1                *
*---------------------------------------------------------------------*
SAY      ST    R14,SAYSAVE
         MVC   MSGTEXT,0(R1)
         WTO   MF=(E,MSGWTO)
         L     R14,SAYSAVE
         BR    R14
         EJECT
*---------------------------------------------------------------------*
*   T H E   L I N E   G R O U P   D C B                               *
*                                                                     *
*   DSORG=CX , MACRF=(R,W) , DEVD=BS AND LERB= ALL ASSEMBLED CLEAN ON *
*   THIS SYSTEM.  CPRI WAS REJECTED WITH IHB050 AND IS LEFT OFF.      *
*   EROPT IS DELIBERATELY NOT CODED - CODING EROPT=C DRAWS IHB050     *
*   INCONSISTENT-IGNORED , WHILE LEAVING IT OFF DRAWS IHB254 AND     *
*   PRESETS IT TO C , WHICH IS WHAT WE WANTED.                       *
*---------------------------------------------------------------------*
LINEDCB  DCB   DSORG=CX,MACRF=(R,W),DEVD=BS,DDNAME=BSCLINE,            X
               BFTEK=S,LERB=LERBLK
         SPACE 2
*---------------------------------------------------------------------*
*   T H E   T E R M I N A L   L I S T                                 *
*                                                                     *
*   OPENLST TAKES A SUBLIST OF ENTRIES.  EACH ENTRY IS EMITTED AS RAW *
*   HEX FOLLOWED BY A PROCEDURE FLAG BYTE , THE LAST FLAG CARRYING    *
*   X'80'.  SO THIS GENERATES X'0000' THEN X'81'.                     *
*                                                                     *
*   CONFIRMED BY A REAL RUN - ON A POINT TO POINT CONTENTION LINE    *
*   THE ENTRY IS A PLACEHOLDER AND IS NOT TRANSMITTED.  THE PARTNER   *
*   TRACE SHOWED THE ENQ WITH NO X'0000' AHEAD OF IT.                 *
*---------------------------------------------------------------------*
TRMLST   DFTRMLST OPENLST,(0000)
         SPACE 2
*---------------------------------------------------------------------*
*   E C B   L I S T S   F O R   T W A I T                             *
*   ORDINARY OS FORMAT - A FULLWORD PER ECB , X'80' ON THE LAST ONE.  *
*   A DECB BEGINS WITH ITS OWN ECB , SO EACH LIST POINTS AT ITS DECB. *
*---------------------------------------------------------------------*
         DS    0F
WECBL    DC    X'80',AL3(WDECB)
EECBL    DC    X'80',AL3(EDECB)
RECBL    DC    X'80',AL3(RDECB)
TECBL    DC    X'80',AL3(TDECB)
         SPACE 2
*---------------------------------------------------------------------*
*   B U F F E R S                                                     *
*---------------------------------------------------------------------*
         DS    0F
TXTAREA  DS    0CL62
         DC    X'02'               STX
TXTDATA  DC    CL60' '             THE PAYLOAD
         DC    X'03'               ETX
TXTEND   EQU   *
TXTLEN   EQU   TXTEND-TXTAREA
         SPACE 1
MSGSEND  DC    CL60'HELLO FROM MVS 3.8J - BSCPOCB VIA BTAM'
         SPACE 1
         DS    0F
INAREA   DS    CL256
         SPACE 1
         DS    0F
LERBLK   DC    XL16'00'            LOGICAL ERROR RECORDING BLOCK
         SPACE 2
*---------------------------------------------------------------------*
*   W T O   P A R A M E T E R   L I S T   (BUILT BY HAND)             *
*---------------------------------------------------------------------*
         DS    0F
MSGWTO   DC    AL2(MSGWEND-MSGWTO)
         DC    XL2'0000'
MSGTEXT  DC    CL62' '
MSGWEND  EQU   *
         SPACE 2
*---------------------------------------------------------------------*
*   W O R K   A R E A S                                               *
*---------------------------------------------------------------------*
         DS    0F
SAVEAREA DS    18F
SAYSAVE  DS    F
DMPSAVE  DS    F
SHWSAVE  DS    F
DCBSAVE  DS    F
F15      DC    F'15'
RETCODE  DC    X'00'
HEXOUT   DC    CL46' '
BLANKS   DC    CL46' '
HEXTAB   DC    C'0123456789ABCDEF'
         SPACE 2
*---------------------------------------------------------------------*
*   M E S S A G E S   -  ALL PADDED TO 62 BYTES                       *
*---------------------------------------------------------------------*
MSG010   DC    CL62'BSCPOCB 010 OPENING BTAM LINE GROUP - DD BSCLINE'
MSG012   DC    CL62'BSCPOCB 012 OPEN FAILED - LOOK FOR AN IEC MESSAGE'
MSG015   DC    CL62'BSCPOCB 015 LINE GROUP IS OPEN'
MSG030   DC    CL62'BSCPOCB 030 WRITE TI - BID AND SEND ONE BLOCK'
MSG032   DC    CL62'BSCPOCB 032 WRITE TI DID NOT POST NORMAL'
MSG034   DC    CL62'BSCPOCB 034 WRITE TI COMPLETED NORMALLY'
MSG042   DC    CL62'BSCPOCB 042 WRITE TR DID NOT POST NORMAL'
MSG044   DC    CL62'BSCPOCB 044 WRITE TR DONE - OUR TURN IS OVER'
MSG050   DC    CL62'BSCPOCB 050 READ TI - WAITING FOR THE PARTNER'
MSG052   DC    CL62'BSCPOCB 052 READ TI DID NOT POST NORMAL'
MSG054   DC    CL62'BSCPOCB 054 READ TI COMPLETED NORMALLY'
MSG062   DC    CL62'BSCPOCB 062 READ TT NOT NORMAL - MAY BE THE EOT'
MSG064   DC    CL62'BSCPOCB 064 READ TT COMPLETED NORMALLY'
MSG992   DC    CL62'BSCPOCB 992 BTAM POSTED AN ERROR - SEE ABOVE'
MSG999   DC    CL62'BSCPOCB 999 ENDING'
MSGHEX   DC    CL62'BSCPOCB 900 HEX='
MSGTXTP  DC    CL62'BSCPOCB 910 TXT='
         SPACE 2
         END   BSCPOCB
/*
//GO.BSCLINE  DD UNIT=090
//GO.SYSUDUMP DD SYSOUT=*
//
