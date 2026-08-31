*---------------------------------------------------------------------*
*                                                                     *
*   A S Y P O C  -  ASYNC (START STOP) TTY LINE PROOF OF CONCEPT      *
*                                                                     *
*   TARGET   : MVS 3.8J , OS/VS ASSEMBLER F  (ASMF)                   *
*   DEVICE   : IBM 2703 TRANSMISSION CONTROL RUNNING AN ASYNCHRONOUS  *
*              START STOP TTY LINE , EMULATED BY HERCULES AND MAPPED  *
*              ONTO A TCP SOCKET.  TELNET INTO THE SOCKET AND TYPE.   *
*                                                                     *
*   THIS IS THE ASYNC COUSIN OF BSCPOC.  ASYNC HAS NO LINE DISCIPLINE *
*   TO SPEAK OF - NO BID , NO ACK , NO BLOCK CHECK - SO ALL THAT IS   *
*   LEFT IS WRITE , PREPARE , READ , AND THE QUESTION OF WHAT CODE    *
*   THE BYTES ARE IN.                                                 *
*                                                                     *
*   WHAT IT DOES                                                      *
*     1. OPEN A DCB FOR EXCP AGAINST THE LINE (DDNAME TTYLINE)        *
*     2. ENABLE THE LINE                                              *
*     3. WRITE A GREETING                                             *
*     4. LOOP UP TO 10 TIMES                                          *
*          WRITE A PROMPT                                             *
*          PREPARE + READ ONE TYPED LINE                              *
*          DUMP IT RAW IN HEX , THEN SHOW IT AS TEXT                  *
*          ECHO IT BACK TO THE TERMINAL                               *
*          STOP EARLY IF THE LINE READS BYE                           *
*     5. DISABLE THE LINE AND CLOSE                                   *
*                                                                     *
*   C O D E   T R A N S L A T I O N                                   *
*                                                                     *
*   IT IS NOT OBVIOUS WHETHER THE EMULATED ADAPTER HANDS THE CHANNEL  *
*   ASCII OR EBCDIC , SO THIS PROGRAM MAKES THAT SWITCHABLE AND       *
*   INSTRUMENTS IT.  THE RAW BYTES ARE ALWAYS DUMPED IN HEX BEFORE    *
*   ANY TRANSLATION , SO ONE RUN SETTLES THE QUESTION.                *
*                                                                     *
*        PARM='Y'  OR NO PARM  - THIS PROGRAM TRANSLATES  (DEFAULT)   *
*        PARM='N'              - ASSUME THE EMULATOR TRANSLATES       *
*                                                                     *
*   IF THE HEX DUMP OF A TYPED 'A' SHOWS 41 THE LINE IS GIVING US     *
*   ASCII AND PARM='Y' IS RIGHT.  IF IT SHOWS C1 IT IS ALREADY        *
*   EBCDIC AND YOU WANT PARM='N'.                                     *
*                                                                     *
*   ALL I/O IS EXCP WITH A HAND BUILT IOB , THE SAME WAY BSCPOC DOES  *
*   IT , SO NOTHING HERE DEPENDS ON TCAM OR BTAM BEING GENNED.        *
*                                                                     *
*   RETURN CODE  0 = OK / 8 = I/O ERROR / 12 = OPEN FAILED            *
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
*   EBCDIC CONTROL CHARACTERS WE CARE ABOUT
EBCR     EQU   X'0D'               CARRIAGE RETURN
EBLF     EQU   X'25'               LINE FEED
EBNL     EQU   X'15'               NEW LINE
EBBLANK  EQU   X'40'
         SPACE 1
INLEN    EQU   256                 SIZE OF THE LINE INPUT BUFFER
OUTMAX   EQU   132                 SIZE OF THE LINE OUTPUT BUFFER
HEXMAX   EQU   23                  BYTES SHOWN BY THE HEX DUMP
HEXLEN   EQU   46                  ... WHICH IS 46 PRINT POSITIONS
TXTMAX   EQU   46                  TEXT CHARACTERS SHOWN BY A WTO
MAXTURN  EQU   10                  HOW MANY LINES WE WILL ACCEPT
ECHOMAX  EQU   70                  TEXT THE ECHO AREA HOLDS
ECHOPFXL EQU   10                  LENGTH OF THE ECHO PREFIX
         EJECT
ASYPOC   CSECT
         STM   R14,R12,12(R13)     SAVE CALLERS REGISTERS
         LR    R12,R15             LOAD OUR BASE
         USING ASYPOC,R12
         LR    R11,R1              KEEP THE PARM POINTER
         LA    R2,SAVEAREA
         ST    R13,4(R2)           BACKWARD CHAIN
         ST    R2,8(R13)           FORWARD CHAIN
         LR    R13,R2
         MVI   RETCODE,X'00'
         SPACE 1
*---------------------------------------------------------------------*
*   PARM HANDLING.  ANYTHING STARTING WITH N TURNS TRANSLATION OFF.   *
*---------------------------------------------------------------------*
         MVI   XLATE,C'Y'
         LTR   R11,R11
         BZ    PARMDONE
         L     R2,0(R11)           ADDRESS OF THE PARM FIELD
         LTR   R2,R2
         BZ    PARMDONE
         LH    R3,0(R2)            ITS LENGTH
         LTR   R3,R3
         BNP   PARMDONE
         CLI   2(R2),C'N'
         BNE   PARMDONE
         MVI   XLATE,C'N'
PARMDONE EQU   *
         LA    R1,MSG070
         CLI   XLATE,C'Y'
         BE    PARMSAY
         LA    R1,MSG072
PARMSAY  BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   OPEN THE LINE DCB.                                                *
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
*   ENABLE THE LINE.  WITH HERCULES THIS IS WHERE WE WAIT FOR THE     *
*   TELNET SESSION TO ARRIVE.  A FAILURE IS ONLY WARNED ABOUT.        *
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
*   GREET THE TERMINAL.                                               *
*---------------------------------------------------------------------*
         LA    R1,GREET1
         LA    R0,L'GREET1
         BAL   R14,SENDTXT
         LA    R1,GREET2
         LA    R0,L'GREET2
         BAL   R14,SENDTXT
         LA    R1,MSG030
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   THE CONVERSATION LOOP.                                            *
*---------------------------------------------------------------------*
         LA    R10,MAXTURN
MAINLOOP EQU   *
         LA    R1,PROMPT
         LA    R0,L'PROMPT
         BAL   R14,SENDRAW         PROMPT , NO CR LF AFTER IT
         LTR   R15,R15
         BNZ   IOFAIL
         SPACE 1
         BAL   R14,GETLIN
         LTR   R15,R15
         BZ    GOTLINE
         LA    R0,8
         CR    R15,R0              8 MEANS A HARD I/O ERROR
         BE    IOFAIL
         LA    R1,MSG980           OTHERWISE JUST AN EMPTY LINE
         BAL   R14,SAY
         B     NEXTTURN
GOTLINE  EQU   *
*        R1 = ADDRESS OF THE TEXT , R0 = ITS LENGTH , ALREADY
*        TRANSLATED AND WITH THE LINE ENDING STRIPPED OFF.  SAVE THEM
*        BEFORE ANYTHING ELSE - WTO DESTROYS R0 R1 AND R15.
         ST    R1,TXTADDR
         ST    R0,TXTLEN
         LA    R1,MSG040
         BAL   R14,SAY
         BAL   R14,SHOWTXT
         SPACE 1
*        DID THEY TYPE BYE ?
         L     R0,TXTLEN
         C     R0,F3
         BL    NOTBYE
         L     R1,TXTADDR
         CLC   0(3,R1),BYEUC
         BE    SAIDBYE
         CLC   0(3,R1),BYELC
         BE    SAIDBYE
NOTBYE   EQU   *
         SPACE 1
*        ECHO THE LINE BACK TO THE TERMINAL.
         MVI   ECHOTXT,EBBLANK
         MVC   ECHOTXT+1(ECHOMAX-1),ECHOTXT
         L     R5,TXTLEN
         LTR   R5,R5
         BNP   ECHOSEND
         LA    R9,ECHOMAX
         CR    R5,R9
         BNH   ECHOMOVE
         LR    R5,R9               TRUNCATE TO WHAT THE AREA HOLDS
ECHOMOVE L     R1,TXTADDR
         LR    R9,R5
         BCTR  R9,0
         EX    R9,ECHOMVC
ECHOSEND LA    R0,ECHOPFXL(R5)     PREFIX PLUS THE TEXT
         LA    R1,ECHOAREA
         BAL   R14,SENDTXT
         LTR   R15,R15
         BNZ   IOFAIL
NEXTTURN BCT   R10,MAINLOOP
         LA    R1,MSG060
         BAL   R14,SAY
         B     FINISH
         SPACE 1
SAIDBYE  LA    R1,MSG050
         BAL   R14,SAY
         LA    R1,FAREWELL
         LA    R0,L'FAREWELL
         BAL   R14,SENDTXT
         B     FINISH
         SPACE 1
IOFAIL   LA    R1,MSG992
         BAL   R14,SAY
         MVI   RETCODE,X'08'
         SPACE 1
*---------------------------------------------------------------------*
*   DISABLE THE LINE AND CLOSE.                                       *
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
ECHOMVC  MVC   ECHOTXT(1),0(R1)         EXECUTED , LENGTH FROM R9
         EJECT
*---------------------------------------------------------------------*
*   S E N D T X T  /  S E N D R A W                                   *
*                                                                     *
*   SENDTXT SENDS THE TEXT FOLLOWED BY A LINE ENDING.                 *
*   SENDRAW SENDS IT WITH NOTHING APPENDED - USED FOR THE PROMPT.     *
*                                                                     *
*   THE LINE ENDING IS APPENDED AS EBCDIC CR AND LF BEFORE ANY        *
*   TRANSLATION , SO IT COMES OUT AS X'0D0A' WHEN WE TRANSLATE AND    *
*   STAYS X'0D25' WHEN THE EMULATOR IS DOING IT.                      *
*                                                                     *
*   ENTRY  R1 = TEXT ADDRESS , R0 = LENGTH                            *
*   EXIT   R15 = 0 OK / 8 ERROR                                       *
*---------------------------------------------------------------------*
SENDTXT  MVI   ADDEOL,C'Y'
         B     SENDGO
SENDRAW  MVI   ADDEOL,C'N'
SENDGO   ST    R14,SNDSAVE
         LR    R6,R1
         LR    R7,R0
         SR    R15,R15
         LTR   R7,R7
         BNP   SNDEXIT
         LA    R9,OUTMAX-2
         CR    R7,R9
         BNH   SNDMOVE
         LR    R7,R9               NEVER OVERRUN THE OUTPUT AREA
SNDMOVE  LR    R9,R7
         BCTR  R9,0
         EX    R9,SNDMVC
         CLI   ADDEOL,C'Y'
         BNE   SNDXLAT
         LA    R4,OUTAREA
         AR    R4,R7
         MVI   0(R4),EBCR
         MVI   1(R4),EBLF
         LA    R7,2(R7)
SNDXLAT  CLI   XLATE,C'Y'
         BNE   SNDWRITE
         LR    R9,R7
         BCTR  R9,0
         EX    R9,SNDTR
SNDWRITE LA    R1,OUTAREA
         LR    R0,R7
         BAL   R14,SENDLIN
SNDEXIT  L     R14,SNDSAVE
         BR    R14
SNDMVC   MVC   OUTAREA(1),0(R6)         EXECUTED , LENGTH FROM R9
SNDTR    TR    OUTAREA(1),EBC2ASC       EXECUTED , LENGTH FROM R9
         SPACE 2
*---------------------------------------------------------------------*
*   S E N D L I N  -  WRITE RAW BYTES TO THE LINE                     *
*   ENTRY R1 = ADDRESS , R0 = LENGTH.  EXIT R15 = 0 OK / 8 ERROR.     *
*---------------------------------------------------------------------*
SENDLIN  ST    R14,SNLSAVE
         ST    R1,CCWWRITE         PLANT THE DATA ADDRESS
         MVI   CCWWRITE,X'01'      ... AND RESTORE THE WRITE OPCODE
         STH   R0,CCWWRITE+6       PLANT THE BYTE COUNT
         LA    R1,CCWWRITE
         BAL   R14,DOIO
         L     R14,SNLSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   G E T L I N  -  PREPARE + READ ONE TYPED LINE                     *
*                                                                     *
*   DUMPS THE RAW BYTES IN HEX , THEN TRANSLATES IF ASKED TO , THEN   *
*   STRIPS THE TRAILING LINE ENDING AND BLANKS.                       *
*                                                                     *
*   EXIT   R1 = TEXT ADDRESS , R0 = LENGTH                            *
*          R15 = 0 OK / 4 NOTHING USABLE / 8 I/O ERROR                *
*---------------------------------------------------------------------*
GETLIN   ST    R14,GETSAVE
         MVI   INAREA,X'00'
         MVC   INAREA+1(INLEN-1),INAREA   CLEAR THE INPUT BUFFER
         LA    R1,INAREA
         ST    R1,CCWREAD+8        PLANT THE ADDRESS IN THE READ CCW
         MVI   CCWREAD+8,X'02'     ... AND RESTORE THE READ OPCODE
         LA    R0,INLEN
         STH   R0,CCWREAD+14
         LA    R1,CCWREAD          PREPARE , CHAINED TO THE READ
         BAL   R14,DOIO
         LTR   R15,R15
         BNZ   GETEXIT
         LA    R2,INLEN
         LH    R3,IOBRESID
         SR    R2,R3               R2 = BYTES ACTUALLY RECEIVED
         LTR   R2,R2
         BNP   GETNONE
         SPACE 1
*        SHOW THE RAW BYTES BEFORE ANYTHING TOUCHES THEM.
         LA    R1,INAREA
         LR    R0,R2
         BAL   R14,DUMPHEX
         SPACE 1
*        TRANSLATE INTO EBCDIC IF WE ARE THE ONES DOING IT.
         CLI   XLATE,C'Y'
         BNE   GETSTRIP
         LR    R9,R2
         BCTR  R9,0
         EX    R9,GETTR
         SPACE 1
*        STRIP THE TRAILING LINE ENDING AND ANY PADDING.
GETSTRIP LTR   R2,R2
         BNP   GETNONE
         LA    R4,INAREA
         AR    R4,R2
         BCTR  R4,0                POINT AT THE LAST BYTE
         CLI   0(R4),EBCR
         BE    GETCHOP
         CLI   0(R4),EBLF
         BE    GETCHOP
         CLI   0(R4),EBNL
         BE    GETCHOP
         CLI   0(R4),EBBLANK
         BE    GETCHOP
         CLI   0(R4),X'00'
         BNE   GETDONE
GETCHOP  BCTR  R2,0
         B     GETSTRIP
GETDONE  LA    R1,INAREA
         LR    R0,R2
         SR    R15,R15
         B     GETEXIT
GETNONE  LA    R1,INAREA
         SR    R0,R0
         LA    R15,4
GETEXIT  L     R14,GETSAVE
         BR    R14
GETTR    TR    INAREA(1),ASC2EBC        EXECUTED , LENGTH FROM R9
         SPACE 2
*---------------------------------------------------------------------*
*   D O I O  -  EXECUTE ONE CHANNEL PROGRAM AND WAIT FOR IT           *
*   ENTRY R1 = ADDRESS OF THE FIRST CCW.                              *
*   EXIT  R15 = 0 NORMAL / 8 ERROR (ALREADY REPORTED).                *
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
         CLI   IOECB,X'7F'
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
*   S H O W T X T  -  WTO THE TEXT OF THE LINE JUST RECEIVED          *
*---------------------------------------------------------------------*
SHOWTXT  ST    R14,SHWSAVE
         MVC   MSGTEXT,MSGTXTP
         L     R7,TXTLEN
         LTR   R7,R7
         BNP   SHWOUT
         LA    R9,TXTMAX
         CR    R7,R9
         BNH   SHWMOVE
         LR    R7,R9               TRUNCATE TO WHAT FITS IN A WTO
SHWMOVE  L     R6,TXTADDR
         BCTR  R7,0
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
*   C H A N N E L   P R O G R A M S                                   *
*                                                                     *
*   270X START STOP COMMAND CODES USED HERE                           *
*        X'01' WRITE     X'02' READ      X'06' PREPARE                *
*        X'27' ENABLE    X'2F' DISABLE                                *
*                                                                     *
*   PREPARE IS THE ASYNC ONE WORTH KNOWING - IT WAITS FOR THE FIRST   *
*   CHARACTER TO ARRIVE WITHOUT TRANSFERRING ANYTHING , AND IS        *
*   COMMAND CHAINED (FLAG X'40') INTO THE READ THAT FOLLOWS IT.  IF   *
*   YOUR EMULATION DOES NOT IMPLEMENT PREPARE , CHANGE THE X'06' TO   *
*   X'03' (NO-OP) AND THE READ ALONE WILL STILL WORK.                 *
*---------------------------------------------------------------------*
CCWENABL CCW   X'27',DUMMY,X'20',1
CCWDISAB CCW   X'2F',DUMMY,X'20',1
CCWWRITE CCW   X'01',DUMMY,X'20',1      ADDRESS+COUNT SET AT RUN TIME
CCWREAD  CCW   X'06',DUMMY,X'60',1      PREPARE , CHAIN INTO THE READ
         CCW   X'02',DUMMY,X'20',1      ADDRESS+COUNT SET AT RUN TIME
DUMMY    DC    X'00'
         SPACE 2
*---------------------------------------------------------------------*
*   I N P U T   O U T P U T   B L O C K   (IOB)                       *
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
*   B U F F E R S   A N D   T E X T                                   *
*---------------------------------------------------------------------*
         DS    0F
INAREA   DS    CL256
         DS    0F
OUTAREA  DS    CL132
         SPACE 1
         DS    0F
ECHOAREA DS    0CL80
         DC    CL10'YOU SAID: '
ECHOTXT  DC    CL70' '
         SPACE 1
GREET1   DC    C'ASYPOC ON MVS 3.8J - ASYNC TTY LINE PROOF OF CONCEPT'
GREET2   DC    C'TYPE A LINE AND PRESS ENTER.  TYPE BYE TO FINISH.'
PROMPT   DC    C'> '
FAREWELL DC    C'ASYPOC SIGNING OFF.  GOODBYE.'
BYEUC    DC    C'BYE'
BYELC    DC    C'bye'
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
SNDSAVE  DS    F
SNLSAVE  DS    F
GETSAVE  DS    F
DMPSAVE  DS    F
SHWSAVE  DS    F
DOIOSAVE DS    F
TXTADDR  DS    F
TXTLEN   DS    F
F15      DC    F'15'
F3       DC    F'3'
RETCODE  DC    X'00'
XLATE    DC    C'Y'                Y = THIS PROGRAM TRANSLATES
ADDEOL   DC    C'Y'
ERRINFO  DC    XL8'00'
HEXOUT   DC    CL46' '
BLANKS   DC    CL46' '
HEXTAB   DC    C'0123456789ABCDEF'
         SPACE 2
*---------------------------------------------------------------------*
*   M E S S A G E S   -  ALL PADDED TO 62 BYTES                       *
*---------------------------------------------------------------------*
MSG010   DC    CL62'ASYPOC 010 OPENING LINE DCB - DDNAME TTYLINE'
MSG012   DC    CL62'ASYPOC 012 OPEN FAILED - IS TTYLINE DD ALLOCATED'
MSG015   DC    CL62'ASYPOC 015 LINE DCB IS OPEN'
MSG020   DC    CL62'ASYPOC 020 ENABLE - WAITING FOR THE TERMINAL'
MSG022   DC    CL62'ASYPOC 022 ENABLE FAILED - CONTINUING ANYWAY'
MSG030   DC    CL62'ASYPOC 030 GREETING SENT - WAITING FOR INPUT'
MSG040   DC    CL62'ASYPOC 040 LINE RECEIVED - TEXT FOLLOWS'
MSG050   DC    CL62'ASYPOC 050 BYE RECEIVED - ENDING THE SESSION'
MSG060   DC    CL62'ASYPOC 060 TURN LIMIT REACHED - ENDING'
MSG070   DC    CL62'ASYPOC 070 TRANSLATION ON - THIS PROGRAM CONVERTS'
MSG072   DC    CL62'ASYPOC 072 TRANSLATION OFF - EMULATOR CONVERTS'
MSG900   DC    CL62'ASYPOC 900 I/O ERROR - ECB SENSE STATUS RESID'
MSG980   DC    CL62'ASYPOC 980 READ RETURNED NO USABLE DATA'
MSG992   DC    CL62'ASYPOC 992 PERMANENT I/O ERROR ON THE LINE'
MSG999   DC    CL62'ASYPOC 999 ENDING'
MSGHEX   DC    CL62'ASYPOC 900 RAW ='
MSGTXTP  DC    CL62'ASYPOC 910 TEXT='
         SPACE 2
*---------------------------------------------------------------------*
*   T R A N S L A T E   T A B L E S                                   *
*                                                                     *
*   GENERATED FROM CODE PAGE 037 , THEN BIT REVERSED.                 *
*                                                                     *
*   A START STOP LINE SHIFTS EACH CHARACTER OUT LOW ORDER BIT FIRST , *
*   SO THE BYTE THE 2703 WANTS IN STORAGE IS THE MIRROR IMAGE OF THE  *
*   ASCII CODE.  MEASURED ON THE WIRE - WE PUT OUT PLAIN ASCII 'A'    *
*   X'41' AND THE TERMINAL SAW X'02' , WHICH IS X'41' REVERSED AND    *
*   MASKED TO SEVEN BITS.  SO EBC2ASC HOLDS REVERSE(ASCII).           *
*                                                                     *
*   INBOUND THE SAME REVERSAL APPLIES AND THE TOP BIT OF THE ORIGINAL *
*   CHARACTER IS AN EVEN PARITY BIT , WHICH LANDS IN BIT 0 AFTER      *
*   REVERSAL.  SO ASC2EBC IS INDEXED BY THE WIRE BYTE AND HOLDS THE   *
*   EBCDIC FOR REVERSE(BYTE) WITH THE PARITY BIT MASKED OFF.          *
*                                                                     *
*   EBCDIC CR X'0D' STILL COMES OUT AS THE CORRECT LINE CODE AND      *
*   ARRIVES BACK AS EBCDIC X'0D' , SO THE STRIP LOGIC IS UNCHANGED.   *
*   CODE POINTS A TTY CANNOT SHOW BECOME A FULL STOP.                 *
*---------------------------------------------------------------------*
EBC2ASC  DC    X'008040C074907474747474D030B070F0'
         DC    X'088848C8747410741898747438B878F8'
         DC    X'747474747450E8D87474747474A060E0'
         DC    X'74746874747474207474747428A87458'
         DC    X'0474747474747474747474743C14D43E'
         DC    X'6474747474747474747484245494DC74'
         DC    X'B4F474747474747474747434A4FA7CFC'
         DC    X'747474747474747474065CC402E4BC44'
         DC    X'748646C626A666E61696747474747474'
         DC    X'7456D636B676F60E8E4E747474747474'
         DC    X'747ECE2EAE6EEE1E9E5E747474747474'
         DC    X'7A747474747474747474DABA74747474'
         DC    X'DE8242C222A262E21292747474747474'
         DC    X'BE52D232B272F20A8A4A747474747474'
         DC    X'3A74CA2AAA6AEA1A9A5A747474747474'
         DC    X'0C8C4CCC2CAC6CEC1C9C747474747474'
         SPACE 1
ASC2EBC  DC    X'00007C7C404079791010D7D7F0F09797'
         DC    X'1616C8C84D4D88881818E7E7F8F8A7A7'
         DC    X'3737C4C45B5B84843C3CE3E3F4F4A3A3'
         DC    X'0C0CD3D36B6B93931C1CE0E04C4C4F4F'
         DC    X'0202C2C27F7F82821212D9D9F2F29999'
         DC    X'2525D1D15C5C91913F3FE9E97A7AA9A9'
         DC    X'2E2EC6C6505086863232E5E5F6F6A5A5'
         DC    X'0E0ED5D54B4B95951E1EB0B06E6EA1A1'
         DC    X'0101C1C15A5A81811111D8D8F1F19898'
         DC    X'0505C9C95D5D89891919E8E8F9F9A8A8'
         DC    X'2D2DC5C56C6C85853D3DE4E4F5F5A4A4'
         DC    X'0D0DD4D4606094941D1DBBBB7E7ED0D0'
         DC    X'0303C3C37B7B83831313E2E2F3F3A2A2'
         DC    X'0B0BD2D24E4E92922727BABA5E5EC0C0'
         DC    X'2F2FC7C77D7D87872626E6E6F7F7A6A6'
         DC    X'0F0FD6D6616196961F1F6D6D6F6F0707'
         SPACE 2
*---------------------------------------------------------------------*
*   D C B   -  EXCP , SO DSORG=PS AND MACRF=E                         *
*---------------------------------------------------------------------*
LINEDCB  DCB   DDNAME=TTYLINE,DSORG=PS,MACRF=(E)
         SPACE 2
         END   ASYPOC
