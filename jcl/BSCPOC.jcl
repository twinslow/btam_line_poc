//BSCPOC   JOB (POC),'BSC LINE POC',CLASS=A,MSGCLASS=A,
//             MSGLEVEL=(1,1),REGION=1024K
//*
//* ------------------------------------------------------------------
//*  ASSEMBLE, LINK-EDIT AND RUN THE BSC LINE PROOF OF CONCEPT.
//*
//*  THE GO STEP SITS IN THE ENABLE CCW UNTIL SOMETHING CONNECTS TO
//*  THE HERCULES SOCKET FOR THE LINE, SO START THE PARTNER
//*  (tools/bscpartner.py) BEFORE OR JUST AFTER SUBMITTING THIS JOB.
//*
//*  UNIT=090 ON THE GO.BSCLINE DD CARD IS THE VERIFIED ADDRESS.
//*  CHANGE IT IF YOUR 2703 BSC LINE IS GENNED ELSEWHERE.
//* ------------------------------------------------------------------
//ASM      EXEC ASMFCLG,PARM.ASM='NODECK,LOAD',
//             PARM.LKED='LIST,MAP,LET'
//ASM.SYSIN DD *
*---------------------------------------------------------------------*
*                                                                     *
*   B S C P O C   -  BSC (BISYNC) LINE PROOF OF CONCEPT               *
*                                                                     *
*   TARGET   : MVS 3.8J , OS/VS ASSEMBLER F  (ASMF)                   *
*   DEVICE   : IBM 2703 TRANSMISSION CONTROL , BSC POINT TO POINT     *
*              NON SWITCHED (CONTENTION) , EMULATED BY HERCULES /     *
*              SDL HYPERION AND MAPPED ONTO A TCP/IP SOCKET.          *
*                                                                     *
*   WHAT IT DOES                                                      *
*     1. OPEN A DCB FOR EXCP AGAINST THE LINE  (DDNAME BSCLINE)       *
*     2. ENABLE THE LINE                                              *
*     3. BID FOR THE LINE       WRITE ENQ       / READ  ACK0          *
*     4. SEND ONE TEXT BLOCK    WRITE STX..ETX  / READ  ACK1          *
*     5. END TRANSMISSION       WRITE EOT                             *
*     6. TURN THE LINE AROUND AND RECEIVE ONE BLOCK                   *
*                               READ  ENQ       / WRITE ACK0          *
*                               READ  STX..ETX  / WRITE ACK1          *
*                               READ  EOT                             *
*     7. DISABLE THE LINE AND CLOSE                                   *
*                                                                     *
*   ALL I/O IS DONE WITH EXCP , A HAND BUILT IOB AND HAND BUILT CCW   *
*   CHAINS , SO THAT NOTHING DEPENDS ON WHAT WAS INCLUDED IN THE      *
*   SYSGEN.  THIS IS THE SAME TECHNIQUE HASP / JES2 USES FOR ITS OWN  *
*   BSC RJE LINES.                                                    *
*                                                                     *
*   BTAM IS A SUPPORTED ACCESS METHOD ON OS/VS2 3.8 - SEE GC27-6980 , *
*   OS/VS BTAM.  IF IT IS INSTALLED ON YOUR SYSTEM IT IS THE MORE     *
*   IDIOMATIC CHOICE , SINCE IT RUNS THE LINE DISCIPLINE FOR YOU.     *
*                                                                     *
*   EVERY STEP IS TRACED WITH A WTO SO THE JOB LOG SHOWS THE WHOLE    *
*   CONVERSATION.                                                     *
*                                                                     *
*   RETURN CODE  0 = OK                                               *
*                4 = UNEXPECTED / PROTOCOL RESPONSE                   *
*                8 = PERMANENT I/O ERROR ON THE LINE                  *
*               12 = OPEN OF THE LINE DCB FAILED                      *
*                                                                     *
*---------------------------------------------------------------------*
         PRINT NOGEN
         SPACE 1
*---------------------------------------------------------------------*
*   ALL PURELY ABSOLUTE SYMBOLS ARE DEFINED UP FRONT.  ASSEMBLER F    *
*   RESOLVES USING STATEMENTS AND EXPLICIT LENGTH FIELDS ON THE       *
*   FIRST PASS , SO THESE MUST NOT BE FORWARD REFERENCES.             *
*---------------------------------------------------------------------*
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
*   BSC CONTROL CHARACTERS (EBCDIC)
SOH      EQU   X'01'
STX      EQU   X'02'
ETX      EQU   X'03'
DLE      EQU   X'10'
ETB      EQU   X'26'
ENQ      EQU   X'2D'
SYN      EQU   X'32'
EOT      EQU   X'37'
NAK      EQU   X'3D'
LPAD     EQU   X'55'               LEADING PAD
TPAD     EQU   X'FF'               TRAILING PAD
         SPACE 1
*   BUFFER AND FIELD SIZES
INLEN    EQU   256                 SIZE OF THE LINE INPUT BUFFER
HEXMAX   EQU   23                  BYTES SHOWN BY THE HEX DUMP
HEXLEN   EQU   46                  ... WHICH IS 46 PRINT POSITIONS
TXTMAX   EQU   46                  TEXT CHARACTERS SHOWN BY A WTO
         EJECT
BSCPOC   CSECT
         STM   R14,R12,12(R13)     SAVE CALLERS REGISTERS
         LR    R12,R15             LOAD OUR BASE
         USING BSCPOC,R12
         LA    R2,SAVEAREA
         ST    R13,4(R2)           BACKWARD CHAIN
         ST    R2,8(R13)           FORWARD CHAIN
         LR    R13,R2              OUR SAVE AREA IS NOW CURRENT
         MVI   RETCODE,X'00'
         SPACE 1
*---------------------------------------------------------------------*
*   OPEN THE LINE DCB.  ALLOCATION IS DONE BY THE BSCLINE DD CARD.    *
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
*   STEP 1 - ENABLE THE LINE.                                         *
*   WITH HERCULES AND DIAL=NO THIS IS WHERE WE SIT UNTIL THE TCP/IP   *
*   PARTNER HAS CONNECTED TO THE SOCKET.  A FAILURE HERE IS ONLY      *
*   WARNED ABOUT , SOME EMULATIONS DO NOT NEED THE ENABLE AT ALL.     *
*---------------------------------------------------------------------*
         LA    R1,MSG020
         BAL   R14,SAY
         LA    R1,CCWENABL
         BAL   R14,DOIO
         LTR   R15,R15
         BZ    ENABLOK
         LA    R1,MSG022
         BAL   R14,SAY
ENABLOK  EQU   *
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 2 - BID FOR THE LINE.  WRITE ENQ , EXPECT ACK0.              *
*---------------------------------------------------------------------*
         LA    R1,MSG030
         BAL   R14,SAY
         LA    R1,FRMENQ
         LA    R0,L'FRMENQ
         BAL   R14,SENDFRM
         LTR   R15,R15
         BNZ   IOFAIL
         BAL   R14,GETFRM
         LTR   R15,R15
         BNZ   IOFAIL
         CLC   0(2,R1),ACK0
         BE    BIDOK
         LA    R1,MSG032
         BAL   R14,SAY
         B     PROTFAIL
BIDOK    EQU   *
         LA    R1,MSG034
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 3 - SEND ONE TEXT BLOCK.  STX <TEXT> ETX , EXPECT ACK1.      *
*   NOTE - THE BLOCK CHECK CHARACTER IS GENERATED BY THE ADAPTER ,    *
*   IT IS NOT PART OF THE BUFFER WE HAND TO THE CHANNEL.              *
*---------------------------------------------------------------------*
         LA    R1,MSG040
         BAL   R14,SAY
         MVC   TXTDATA,MSGSEND
         LA    R1,TXTFRAME
         LA    R0,TXTFLEN
         BAL   R14,SENDFRM
         LTR   R15,R15
         BNZ   IOFAIL
         BAL   R14,GETFRM
         LTR   R15,R15
         BNZ   IOFAIL
         CLC   0(2,R1),ACK1
         BE    TXTOK
         LA    R1,MSG042
         BAL   R14,SAY
         B     PROTFAIL
TXTOK    EQU   *
         LA    R1,MSG044
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 4 - END OF TRANSMISSION.                                     *
*---------------------------------------------------------------------*
         LA    R1,FRMEOT
         LA    R0,L'FRMEOT
         BAL   R14,SENDFRM
         LTR   R15,R15
         BNZ   IOFAIL
         LA    R1,MSG050
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 5 - LINE TURNAROUND.  WE ARE NOW THE RECEIVER AND WAIT FOR   *
*   THE PARTNER TO BID FOR THE LINE.                                  *
*---------------------------------------------------------------------*
         LA    R1,MSG060
         BAL   R14,SAY
         BAL   R14,GETFRM
         LTR   R15,R15
         BNZ   IOFAIL
         CLI   0(R1),ENQ
         BE    GOTENQ
         LA    R1,MSG062
         BAL   R14,SAY
         B     PROTFAIL
GOTENQ   EQU   *
         LA    R1,FRMACK0
         LA    R0,L'FRMACK0
         BAL   R14,SENDFRM
         LTR   R15,R15
         BNZ   IOFAIL
         SPACE 1
*---------------------------------------------------------------------*
*   READ THE INBOUND TEXT BLOCK AND ACKNOWLEDGE IT.                   *
*---------------------------------------------------------------------*
         BAL   R14,GETFRM
         LTR   R15,R15
         BNZ   IOFAIL
         CLI   0(R1),STX
         BE    GOTSTX
         LA    R1,MSG064
         BAL   R14,SAY
         B     PROTFAIL
GOTSTX   EQU   *
         BAL   R14,SHOWTXT
         LA    R1,FRMACK1
         LA    R0,L'FRMACK1
         BAL   R14,SENDFRM
         LTR   R15,R15
         BNZ   IOFAIL
         SPACE 1
*---------------------------------------------------------------------*
*   READ THE PARTNERS EOT.                                            *
*---------------------------------------------------------------------*
         BAL   R14,GETFRM
         LTR   R15,R15
         BNZ   IOFAIL
         CLI   0(R1),EOT
         BE    GOTEOT
         LA    R1,MSG066
         BAL   R14,SAY
         B     PROTFAIL
GOTEOT   EQU   *
         LA    R1,MSG070
         BAL   R14,SAY
         B     FINISH
         SPACE 1
*---------------------------------------------------------------------*
*   ERROR EXITS                                                       *
*---------------------------------------------------------------------*
PROTFAIL LA    R1,MSG990
         BAL   R14,SAY
         MVI   RETCODE,X'04'
         B     FINISH
IOFAIL   LA    R1,MSG992
         BAL   R14,SAY
         MVI   RETCODE,X'08'
         B     FINISH
         SPACE 1
*---------------------------------------------------------------------*
*   STEP 6 - DISABLE THE LINE AND CLOSE.                              *
*---------------------------------------------------------------------*
FINISH   EQU   *
         LA    R1,CCWDISAB
         BAL   R14,DOIO
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
*   D O I O    -  EXECUTE ONE CHANNEL PROGRAM AND WAIT FOR IT         *
*                                                                     *
*   ENTRY  R1  = ADDRESS OF THE CHANNEL PROGRAM (FIRST CCW)           *
*   EXIT   R15 = 0 NORMAL COMPLETION , 8 = ERROR (ALREADY REPORTED)   *
*---------------------------------------------------------------------*
DOIO     ST    R14,DOIOSAVE
         ST    R1,IOBSTRT          CCW ADDRESS , CLEARS IOBSIOCC TOO
         XC    IOECB,IOECB
         MVI   IOBFLAG1,X'42'      CMD CHAINING + UNRELATED REQUEST
         MVI   IOBFLAG2,X'00'
         MVI   IOBSENS0,X'00'
         MVI   IOBSENS1,X'00'
         EXCP  IOB
         WAIT  ECB=IOECB
         CLI   IOECB,X'7F'         NORMAL COMPLETION ?
         BNE   DOIOBAD
         SR    R15,R15
         B     DOIOEND
DOIOBAD  LA    R1,MSG900
         BAL   R14,SAY
         MVC   ERRINFO(1),IOECB         ECB COMPLETION CODE
         MVC   ERRINFO+1(2),IOBSENS0    SENSE BYTES 0 AND 1
         MVC   ERRINFO+3(4),IOBSTAT     CSW STATUS + RESIDUAL COUNT
         LA    R1,ERRINFO
         LA    R0,7
         BAL   R14,DUMPHEX
         LA    R15,8
DOIOEND  L     R14,DOIOSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   S E N D F R M  -  WRITE A FRAME TO THE LINE                       *
*                                                                     *
*   ENTRY  R1 = ADDRESS OF FRAME , R0 = LENGTH                        *
*   EXIT   R15 = 0 OK / 8 ERROR                                       *
*---------------------------------------------------------------------*
SENDFRM  ST    R14,SNDSAVE
         ST    R1,CCWWRITE         PLANT DATA ADDRESS
         MVI   CCWWRITE,X'01'      ... AND RESTORE THE WRITE OPCODE
         STH   R0,CCWWRITE+6       PLANT THE BYTE COUNT
         LA    R1,CCWWRITE
         BAL   R14,DOIO
         L     R14,SNDSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   G E T F R M  -  READ A FRAME AND STRIP LEADING PAD / SYN          *
*                                                                     *
*   EXIT   R1  = ADDRESS OF FIRST MEANINGFUL BYTE                     *
*          R0  = NUMBER OF BYTES LEFT FROM THERE                      *
*          R15 = 0 OK / 4 NOTHING RECEIVED / 8 I/O ERROR              *
*   THE RAW FRAME IS ALSO DUMPED IN HEX TO THE JOB LOG.               *
*---------------------------------------------------------------------*
GETFRM   ST    R14,GETSAVE
         MVI   INAREA,X'00'
         MVC   INAREA+1(INLEN-1),INAREA   CLEAR THE INPUT BUFFER
         LA    R1,INAREA
         ST    R1,CCWREAD          PLANT DATA ADDRESS
         MVI   CCWREAD,X'02'       ... AND RESTORE THE READ OPCODE
         LA    R0,INLEN
         STH   R0,CCWREAD+6
         LA    R1,CCWREAD
         BAL   R14,DOIO
         LTR   R15,R15
         BNZ   GETEXIT
         LA    R2,INLEN
         LH    R3,IOBRESID
         SR    R2,R3               R2 = BYTES ACTUALLY RECEIVED
         LA    R1,INAREA
         LTR   R2,R2
         BNP   GETSHORT
GETSKIP  CLI   0(R1),SYN
         BE    GETNEXT
         CLI   0(R1),LPAD
         BE    GETNEXT
         CLI   0(R1),TPAD
         BE    GETNEXT
         CLI   0(R1),X'00'
         BNE   GETGOOD
GETNEXT  LA    R1,1(R1)
         BCT   R2,GETSKIP
         B     GETSHORT
GETGOOD  LR    R4,R1               KEEP THE ADDRESS OVER THE DUMP
         LR    R0,R2
         BAL   R14,DUMPHEX
         LR    R1,R4
         LR    R0,R2
         SR    R15,R15
         B     GETEXIT
GETSHORT LA    R1,MSG980
         BAL   R14,SAY
         LA    R1,INAREA
         SR    R0,R0
         LA    R15,4
GETEXIT  L     R14,GETSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   S H O W T X T  -  DISPLAY THE PAYLOAD OF AN INBOUND TEXT BLOCK    *
*                                                                     *
*   ENTRY  R1 = ADDRESS OF THE STX , R0 = LENGTH FROM THERE           *
*---------------------------------------------------------------------*
SHOWTXT  ST    R14,SHWSAVE
         MVC   MSGTEXT,MSGTXTP
         LR    R6,R1
         LR    R7,R0
         LA    R6,1(R6)            STEP OVER THE STX
         BCTR  R7,0
         LTR   R7,R7
         BNP   SHWOUT
         LR    R8,R6               SCAN FORWARD FOR ETX / ETB
         LR    R9,R7
         SR    R5,R5
SHWSCAN  CLI   0(R8),ETX
         BE    SHWFND
         CLI   0(R8),ETB
         BE    SHWFND
         LA    R8,1(R8)
         LA    R5,1(R5)
         BCT   R9,SHWSCAN
SHWFND   LR    R7,R5               R7 = LENGTH OF THE TEXT ITSELF
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
*                                                                     *
*   ENTRY  R1 = ADDRESS , R0 = LENGTH                                 *
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
*   C H A N N E L   P R O G R A M S                                   *
*                                                                     *
*   2703 BSC COMMAND CODES USED HERE                                  *
*        X'01' WRITE     X'02' READ                                   *
*        X'27' ENABLE    X'2F' DISABLE                                *
*   FLAG X'20' IS SLI - SUPPRESS INCORRECT LENGTH INDICATION , WHICH  *
*   WE NEED BECAUSE INBOUND FRAMES ARE SHORTER THAN THE BUFFER.       *
*---------------------------------------------------------------------*
CCWENABL CCW   X'27',DUMMY,X'20',1
CCWDISAB CCW   X'2F',DUMMY,X'20',1
CCWWRITE CCW   X'01',DUMMY,X'20',1      ADDRESS+COUNT SET AT RUN TIME
CCWREAD  CCW   X'02',DUMMY,X'20',1      ADDRESS+COUNT SET AT RUN TIME
DUMMY    DC    X'00'
         SPACE 2
*---------------------------------------------------------------------*
*   I N P U T   O U T P U T   B L O C K   (IOB)                       *
*   HAND BUILT , STANDARD 32 BYTE OS/VS IOB.                          *
*---------------------------------------------------------------------*
         DS    0F
IOB      EQU   *
IOBFLAG1 DC    X'42'               FLAGS
IOBFLAG2 DC    X'00'
IOBSENS0 DC    X'00'               SENSE BYTE 0
IOBSENS1 DC    X'00'               SENSE BYTE 1
IOBECBP  DC    A(IOECB)            ADDRESS OF OUR ECB
IOBFLAG3 DC    X'00'
         DC    XL7'00'             REST OF THE STORED CSW
IOBSTRT  DC    A(0)                SIOCC + CHANNEL PROGRAM ADDRESS
IOBDCBP  DC    A(LINEDCB)          ADDRESS OF THE DCB
IOBRSTR  DC    A(0)                RESTART ADDRESS
IOBINCAM DC    H'0'
IOBERRCT DC    H'0'
IOBSTAT  EQU   IOB+12              CSW UNIT + CHANNEL STATUS
IOBRESID EQU   IOB+14              CSW RESIDUAL COUNT
         SPACE 1
         DS    0F
IOECB    DC    F'0'
         SPACE 2
*---------------------------------------------------------------------*
*   E X P E C T E D   R E S P O N S E S                               *
*---------------------------------------------------------------------*
ACK0     DC    X'1070'             DLE 0
ACK1     DC    X'1061'             DLE 1
         SPACE 1
*---------------------------------------------------------------------*
*   O U T B O U N D   F R A M E S                                     *
*   EACH ONE CARRIES TWO LEADING SYN CHARACTERS SO THAT A PARTNER     *
*   THAT EXPECTS THEM STAYS HAPPY.  A PARTNER THAT DOES NOT CARE      *
*   SIMPLY SKIPS THEM.                                                *
*---------------------------------------------------------------------*
FRMENQ   DC    X'32322D'           SYN SYN ENQ
FRMEOT   DC    X'323237'           SYN SYN EOT
FRMACK0  DC    X'32321070'         SYN SYN DLE 0
FRMACK1  DC    X'32321061'         SYN SYN DLE 1
FRMNAK   DC    X'32323D'           SYN SYN NAK
         SPACE 1
         DS    0F
TXTFRAME DC    X'3232'             SYN SYN
         DC    X'02'               STX
TXTDATA  DC    CL60' '             THE PAYLOAD
         DC    X'03'               ETX
TXTEND   EQU   *
TXTFLEN  EQU   TXTEND-TXTFRAME
         SPACE 1
MSGSEND  DC    CL60'HELLO FROM MVS 3.8J - BSCPOC BLOCK 001'
         SPACE 2
*---------------------------------------------------------------------*
*   I N P U T   B U F F E R                                           *
*---------------------------------------------------------------------*
         DS    0F
INAREA   DS    CL256
         SPACE 2
*---------------------------------------------------------------------*
*   W T O   P A R A M E T E R   L I S T   (BUILT BY HAND)             *
*   HALFWORD LENGTH , HALFWORD MCS FLAGS , THEN THE TEXT.             *
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
SNDSAVE  DS    F
GETSAVE  DS    F
DMPSAVE  DS    F
SHWSAVE  DS    F
DOIOSAVE DS    F
F15      DC    F'15'
RETCODE  DC    X'00'
ERRINFO  DC    XL8'00'
HEXOUT   DC    CL46' '
BLANKS   DC    CL46' '
HEXTAB   DC    C'0123456789ABCDEF'
         SPACE 2
*---------------------------------------------------------------------*
*   M E S S A G E S   -  ALL PADDED TO 62 BYTES                       *
*---------------------------------------------------------------------*
MSG010   DC    CL62'BSCPOC 010 OPENING LINE DCB - DDNAME BSCLINE'
MSG012   DC    CL62'BSCPOC 012 OPEN FAILED - IS BSCLINE DD ALLOCATED'
MSG015   DC    CL62'BSCPOC 015 LINE DCB IS OPEN'
MSG020   DC    CL62'BSCPOC 020 ENABLE - WAITING FOR THE TCP PARTNER'
MSG022   DC    CL62'BSCPOC 022 ENABLE FAILED - CONTINUING ANYWAY'
MSG030   DC    CL62'BSCPOC 030 BIDDING FOR THE LINE - SENDING ENQ'
MSG032   DC    CL62'BSCPOC 032 EXPECTED ACK0 - GOT SOMETHING ELSE'
MSG034   DC    CL62'BSCPOC 034 ACK0 RECEIVED - THE LINE IS OURS'
MSG040   DC    CL62'BSCPOC 040 SENDING TEXT BLOCK STX ... ETX'
MSG042   DC    CL62'BSCPOC 042 EXPECTED ACK1 - GOT SOMETHING ELSE'
MSG044   DC    CL62'BSCPOC 044 ACK1 RECEIVED - BLOCK ACCEPTED'
MSG050   DC    CL62'BSCPOC 050 EOT SENT - OUR TRANSMISSION IS OVER'
MSG060   DC    CL62'BSCPOC 060 TURNAROUND - WAITING FOR PARTNER BID'
MSG062   DC    CL62'BSCPOC 062 EXPECTED ENQ FROM THE PARTNER'
MSG064   DC    CL62'BSCPOC 064 EXPECTED AN STX TEXT BLOCK'
MSG066   DC    CL62'BSCPOC 066 EXPECTED EOT FROM THE PARTNER'
MSG070   DC    CL62'BSCPOC 070 INBOUND BLOCK RECEIVED AND ACKED'
MSG900   DC    CL62'BSCPOC 900 I/O ERROR - ECB SENSE STATUS RESID'
MSG980   DC    CL62'BSCPOC 980 READ RETURNED NO USABLE DATA'
MSG990   DC    CL62'BSCPOC 990 PROTOCOL ERROR - SEE MESSAGES ABOVE'
MSG992   DC    CL62'BSCPOC 992 PERMANENT I/O ERROR ON THE LINE'
MSG999   DC    CL62'BSCPOC 999 ENDING'
MSGHEX   DC    CL62'BSCPOC 900 RX  ='
MSGTXTP  DC    CL62'BSCPOC 910 TEXT='
         SPACE 2
*---------------------------------------------------------------------*
*   D C B   -  EXCP , SO DSORG=PS AND MACRF=E                         *
*---------------------------------------------------------------------*
LINEDCB  DCB   DDNAME=BSCLINE,DSORG=PS,MACRF=(E)
         SPACE 2
         END   BSCPOC
/*
//GO.BSCLINE  DD UNIT=090
//GO.SYSUDUMP DD SYSOUT=*
//
