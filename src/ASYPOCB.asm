*---------------------------------------------------------------------*
*   S T A T U S  -  THIS PROGRAM CANNOT RUN AS THINGS STAND           *
*                                                                     *
*   BTAM CANNOT OPEN A HERCULES commadpt LINE.  ITS OPEN FOR A        *
*   DSORG=CX LINE GROUP ISSUES  DISABLE (X'2F')  CHAINED TO  X'13' ,  *
*   AND commadpt HAS NO CASE FOR X'13' SO IT ANSWERS COMMAND REJECT.  *
*                                                                     *
*   X'13' IS ONE OF THE STANDARD 2702 COMMANDS THAT A REAL 2703       *
*   ACCEPTS AND TREATS AS AN I/O NO-OP , PRESENT ONLY FOR 2702        *
*   PROGRAMMING COMPATIBILITY.  SO THIS IS AN EMULATION GAP , NOT A   *
*   FAULT IN THIS PROGRAM OR IN BTAM.                                 *
*                                                                     *
*   OPEN STILL COMPLETES AND THE PROGRAM REPORTS THE LINE OPEN , BUT  *
*   NO CHANNEL PROGRAM IS EVER STARTED FOR THE FIRST WRITE , THE ECB  *
*   IS NEVER POSTED , AND TWAIT WAITS FOREVER.                        *
*                                                                     *
*   FIX : ADD THE 2702 COMPATIBILITY COMMANDS TO commadpt's CCW       *
*   DISPATCH AS NO-OPS , MIRRORING THE EXISTING X'03' NOP CASE.       *
*   NOT DONE - NO HERCULES BUILD ENVIRONMENT AVAILABLE.               *
*                                                                     *
*   SEE README.MD AND DOCS/BTAM-NOTES.MD.  THE MACRO SYNTAX IN HERE   *
*   IS ALL VERIFIED AGAINST THE REAL SYSTEM ; ONLY THE LINE ITSELF    *
*   IS UNREACHABLE.                                                   *
*---------------------------------------------------------------------*
*---------------------------------------------------------------------*
*                                                                     *
*   A S Y P O C B  -  THE ASYNC TTY PROOF OF CONCEPT , DONE WITH BTAM *
*                                                                     *
*   TARGET   : MVS 3.8J , OS/VS ASSEMBLER F  (ASMF)                   *
*   DEVICE   : IBM 2703 START STOP TTY LINE (HERCULES lnctl=tele2)    *
*              AT ADDRESS 0684 , DDNAME TTYLINE.                      *
*                                                                     *
*   SAME CONVERSATION AS ASYPOC - GREET , PROMPT , READ A LINE , SHOW *
*   IT , ECHO IT , STOP ON BYE - BUT WITH BTAM READ AND WRITE INSTEAD *
*   OF EXCP.  NO CCWS AND NO IOB.                                     *
*                                                                     *
*   W H A T   I S   C A R R I E D   O V E R   ( P R O V E N )         *
*                                                                     *
*   THE BTAM MACRO SYNTAX WAS ESTABLISHED ON THIS SYSTEM FOR THE BSC  *
*   LINE - SEE DOCS/BTAM-NOTES.MD.  OPERAND ORDER IS                  *
*                                                                     *
*        DECB , TYPE , DCB , AREA , LENGTH , TERMLIST , LINENO        *
*                                                                     *
*   AND THE DECB LAYOUT IS  +0 ECB  +4 FLAGS  +5 TYPE  +6 LENGTH      *
*   +8 DCB  +12 AREA  +16 ERROR INFO  +20 TERMINAL LIST.  THAT LAYOUT *
*   IS WHY SENDLIN AND GETLIN CAN PLANT A RUN TIME ADDRESS AND LENGTH *
*   INTO AN OTHERWISE STATIC DECB.                                    *
*                                                                     *
*   THE BIT REVERSED TRANSLATE TABLES ARE CARRIED OVER FROM ASYPOC    *
*   UNCHANGED - THEY WERE MEASURED ON THE WIRE AND ARE CORRECT.       *
*                                                                     *
*   W H A T   I S   S T I L L   A N   A S S U M P T I O N             *
*                                                                     *
*   ONE THING , MARKED >>> ASSUMPTION <<< BELOW.  DEVD= AND THE       *
*   TERMINAL LIST TYPE ARE NO LONGER GUESSES - JCL/BTAMTTY.JCL        *
*   SETTLED BOTH.                                                     *
*                                                                     *
*     1. OP TYPE TI ON THE READ AND THE WRITE.  IT IS A VALID         *
*        MNEMONIC , BUT WHETHER START STOP WANTS IT RATHER THAN TP    *
*        OR TS IS ONLY ANSWERED BY RUNNING.                           *
*                                                                     *
*   A THIRD UNKNOWN IS DESIGNED AROUND RATHER THAN GUESSED AT - WE DO *
*   NOT KNOW WHERE BTAM POSTS THE RECEIVED LENGTH , SO GETLIN DOES    *
*   NOT ASK.  IT CLEARS THE BUFFER TO X'00' FIRST AND THEN TRIMS BACK *
*   FROM THE END , AND IT DUMPS THE DECB IN HEX SO THE REAL COUNT     *
*   IDENTIFIES ITSELF.                                                *
*                                                                     *
*        PARM='Y' OR NO PARM - THIS PROGRAM TRANSLATES  (DEFAULT)     *
*        PARM='N'            - PASS THE BYTES THROUGH UNTOUCHED       *
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
NORMAL   EQU   X'7F'               ECB POST CODE FOR NORMAL COMPLETION
         SPACE 1
*   DECB FIELD OFFSETS , TAKEN FROM A REAL EXPANSION ON THIS SYSTEM
DECBLEN  EQU   6                   HALFWORD LENGTH
DECBAREA EQU   12                  FULLWORD AREA ADDRESS
DECBLNG  EQU   40                  WHOLE DECB
*        +20 TERMINAL LIST  +24 LINE NUMBER   +26 RESPONSE FIELD
*        +28 TP-OP CODE     +29 ERROR STATUS  +30 CSW STATUS
*        +32 CURRENT ADDR LIST PTR            +36 CURRENT ADDR POLL PTR
         EJECT
ASYPOCB  CSECT
         STM   R14,R12,12(R13)     SAVE CALLERS REGISTERS
         LR    R12,R15             LOAD OUR BASE
         USING ASYPOCB,R12
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
*   OPEN THE LINE GROUP.  THIS IS ALSO THE TEST OF WHETHER THE BTAM   *
*   MODULES ARE INSTALLED.  IF IT FAILS , LOOK FOR AN IEC MESSAGE.    *
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
*   GREET THE TERMINAL.  BTAM WAITS FOR THE LINE ITSELF , SO THERE IS *
*   NO ENABLE STEP TO CODE HERE THE WAY THERE WAS UNDER EXCP.         *
*---------------------------------------------------------------------*
         LA    R1,GREET1
         LA    R0,L'GREET1
         BAL   R14,SENDTXT
         LTR   R15,R15
         BNZ   IOFAIL
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
         CR    R15,R0              8 MEANS BTAM POSTED AN ERROR
         BE    IOFAIL
         LA    R1,MSG980           OTHERWISE JUST AN EMPTY LINE
         BAL   R14,SAY
         B     NEXTTURN
GOTLINE  EQU   *
*        SAVE GETLIN'S R1 AND R0 BEFORE ANYTHING ISSUES A WTO -
*        WTO DESTROYS R0 R1 AND R15.
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
ECHOMVC  MVC   ECHOTXT(1),0(R1)         EXECUTED , LENGTH FROM R9
         EJECT
*---------------------------------------------------------------------*
*   S E N D T X T  /  S E N D R A W                                   *
*                                                                     *
*   SENDTXT APPENDS A LINE ENDING , SENDRAW DOES NOT.  THE ENDING IS  *
*   APPENDED AS EBCDIC CR AND LF BEFORE TRANSLATION , SO IT COMES OUT *
*   IN THE RIGHT LINE CODE EITHER WAY.                                *
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
*   S E N D L I N  -  BTAM WRITE                                      *
*                                                                     *
*   THE WRITE MACRO LAYS ITS DECB DOWN AS CONSTANTS IN THE CODE       *
*   STREAM , SO THE AREA AND LENGTH IT WAS ASSEMBLED WITH ARE ONLY    *
*   PLACEHOLDERS.  WE PLANT THE REAL ONES FIRST.  THIS IS THE SAME    *
*   THING ONE DOES WITH A BSAM DECB.                                  *
*                                                                     *
*   >>> ASSUMPTION <<<  OP TYPE TI.  IT IS A VALID MNEMONIC - THE    *
*   MACRO GIVES IT TYPE CODE 1 FOR READ AND 2 FOR WRITE - BUT        *
*   WHETHER IT IS THE RIGHT ONE FOR START STOP IS A RUN TIME         *
*   QUESTION.  THE OTHER VALID ONES ARE IN DOCS/BTAM-NOTES.MD.       *
*                                                                     *
*   ENTRY R1 = ADDRESS , R0 = LENGTH.  EXIT R15 = 0 OK / 8 ERROR.     *
*---------------------------------------------------------------------*
SENDLIN  ST    R14,SNLSAVE
         ST    R1,WDECB+DECBAREA   PLANT THE REAL AREA ADDRESS
         STH   R0,WDECB+DECBLEN    PLANT THE REAL LENGTH
         XC    WDECB(4),WDECB      CLEAR THE ECB BEFORE REUSING IT
         WRITE WDECB,TI,LINEDCB,OUTAREA,1,TRMLST,1
         TWAIT (R4),ECBLIST=WECBL
         CLI   WDECB,NORMAL
         BE    SNLGOOD
         LA    R1,MSG910
         BAL   R14,SAY
         LA    R1,WDECB
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
         LA    R15,8
         B     SNLEND
SNLGOOD  SR    R15,R15
SNLEND   L     R14,SNLSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   G E T L I N  -  BTAM READ                                         *
*                                                                     *
*   THE INPUT AREA IS CLEARED TO X'00' FIRST, AND THE LENGTH IS FOUND *
*   BY TRIMMING BACK FROM THE END OF THE BUFFER RATHER THAN BY ASKING *
*   BTAM - WE DO NOT YET KNOW WHERE IT POSTS THE COUNT.  THE DECB IS  *
*   DUMPED IN HEX SO THAT THE COUNT CAN BE FOUND AND THIS REPLACED    *
*   WITH SOMETHING LESS BLUNT.                                        *
*                                                                     *
*   >>> ASSUMPTION <<<  OP TYPE TI.  IT IS A VALID MNEMONIC - THE    *
*   MACRO GIVES IT TYPE CODE 1 FOR READ AND 2 FOR WRITE - BUT        *
*   WHETHER IT IS THE RIGHT ONE FOR START STOP IS A RUN TIME         *
*   QUESTION.  THE OTHER VALID ONES ARE IN DOCS/BTAM-NOTES.MD.       *
*                                                                     *
*   EXIT R1 = TEXT ADDRESS , R0 = LENGTH                              *
*        R15 = 0 OK / 4 NOTHING USABLE / 8 BTAM ERROR                 *
*---------------------------------------------------------------------*
GETLIN   ST    R14,GETSAVE
         MVI   INAREA,X'00'
         MVC   INAREA+1(INLEN-1),INAREA   CLEAR THE INPUT BUFFER
         LA    R1,INAREA
         ST    R1,RDECB+DECBAREA
         LA    R0,INLEN
         STH   R0,RDECB+DECBLEN
         XC    RDECB(4),RDECB      CLEAR THE ECB BEFORE REUSING IT
         READ  RDECB,TI,LINEDCB,INAREA,1,TRMLST,1
         TWAIT (R4),ECBLIST=RECBL
         CLI   RDECB,NORMAL
         BE    GETGOOD
         LA    R1,MSG910
         BAL   R14,SAY
         LA    R1,RDECB
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
         LA    R15,8
         B     GETEXIT
GETGOOD  EQU   *
*        SHOW THE RAW BYTES AND THE DECB BEFORE ANYTHING TOUCHES THEM
         LA    R1,INAREA
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
         LA    R1,MSG920
         BAL   R14,SAY
         LA    R1,RDECB
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
         LA    R1,RDECB+HEXMAX
         LA    R0,DECBLNG-HEXMAX
         BAL   R14,DUMPHEX
         SPACE 1
*        TRANSLATE THE WHOLE BUFFER IF WE ARE THE ONES DOING IT.
*        X'00' TRANSLATES TO X'00' , SO THE PADDING SURVIVES INTACT
*        AND THE TRIM BELOW STILL WORKS.
         CLI   XLATE,C'Y'
         BNE   GETTRIM
         LA    R9,INLEN-1
         EX    R9,GETTR
         SPACE 1
*        TRIM THE PADDING AND THE LINE ENDING OFF THE BACK.
GETTRIM  LA    R2,INLEN
GETSTRIP LTR   R2,R2
         BNP   GETNONE
         LA    R4,INAREA
         AR    R4,R2
         BCTR  R4,0                POINT AT THE LAST BYTE
         CLI   0(R4),X'00'
         BE    GETCHOP
         CLI   0(R4),EBCR
         BE    GETCHOP
         CLI   0(R4),EBLF
         BE    GETCHOP
         CLI   0(R4),EBNL
         BE    GETCHOP
         CLI   0(R4),EBBLANK
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
*   T H E   L I N E   G R O U P   D C B                               *
*                                                                     *
*   DSORG=CX , MACRF=(R,W) , EROPT= , BFTEK= AND LERB= ARE ALL PROVEN *
*   ON THIS SYSTEM.  CPRI IS LEFT OFF - IT DREW IHB050 ON THE BSC     *
*   LINE AND IS ONLY MEANINGFUL WITH DYNAMIC BUFFERING.               *
*                                                                     *
*   DEVD IS DELIBERATELY NOT CODED , AND THAT IS THE WHOLE POINT.     *
*                                                                     *
*   THE MANUAL ALLOWS ONLY THREE VALUES - BS BINARY SYNCHRONOUS , WT  *
*   WORLD TRADE TELEGRAPH ADAPTER , LD LOCALLY ATTACHED.  NONE OF     *
*   THEM DESCRIBES AN ORDINARY REMOTE START STOP TTY LINE.  DEVD=WT   *
*   WAS TRIED FIRST AND ITS OPEN ISSUED A X'13' THAT HERCULES         *
*   COMMAND REJECTED , AFTER WHICH BTAM NEVER DROVE THE LINE.         *
*                                                                     *
*   LEAVING DEVD OFF PRODUCES A PROPERLY RECOGNISED LINE GROUP DCB -  *
*   THE MACRO EMITS  ORG *+20  , NOT THE DIRECT ACCESS FALLBACK THAT  *
*   AN INVALID VALUE GETS - AND A 56 BYTE DCB CARRYING JUST THE LERB. *
*   THAT IS THE CORRECT SIZE FOR A LINE TYPE WITH NO CONTROL          *
*   CHARACTER TABLE.  ONLY DEVD=BS GENERATES THE FULL 100 BYTES , AND *
*   ONLY BECAUSE THE 26 BYTE TABLE HOLDS THE BSC CONTROL CHARACTERS.  *
*   DEVD=WT AND DEVD=LD BOTH COME OUT AT 56 BYTES TOO.                *
*                                                                     *
*   EROPT IS DELIBERATELY NOT CODED.  CODING EROPT=C DRAWS IHB050     *
*   EROPT OPERAND INCONSISTENT-IGNORED ; LEAVING IT OFF DRAWS IHB254  *
*   EROPT NOT SPECIFIED-PRESET TO C , WHICH IS THE VALUE WE WANTED    *
*   ANYWAY AND IS THE PATH ACTUALLY MEASURED TO GENERATE X'08'.       *
*---------------------------------------------------------------------*
LINEDCB  DCB   DSORG=CX,MACRF=(R,W),DDNAME=TTYLINE,BFTEK=S,            X
               LERB=LERBLK
         SPACE 2
*---------------------------------------------------------------------*
*   T H E   T E R M I N A L   L I S T                                 *
*                                                                     *
*   OPENLST TAKES A SUBLIST OF ENTRIES.  EACH IS EMITTED AS RAW HEX   *
*   FOLLOWED BY A PROCEDURE FLAG BYTE , THE LAST FLAG CARRYING X'80'  *
*   - SO THIS GENERATES X'0000' THEN X'81'.  ON A POINT TO POINT      *
*   LINE WITH NO ADDRESSING CHARACTERS THE ENTRY IS A PLACEHOLDER.    *
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
RECBL    DC    X'80',AL3(RDECB)
         SPACE 2
*---------------------------------------------------------------------*
*   B U F F E R S   A N D   T E X T                                   *
*---------------------------------------------------------------------*
         DS    0F
INAREA   DS    CL256
         DS    0F
OUTAREA  DS    CL132
         DS    0F
LERBLK   DC    XL16'00'            LOGICAL ERROR RECORDING BLOCK
         SPACE 1
         DS    0F
ECHOAREA DS    0CL80
         DC    CL10'YOU SAID: '
ECHOTXT  DC    CL70' '
         SPACE 1
GREET1   DC    C'ASYPOCB ON MVS 3.8J - ASYNC TTY VIA BTAM'
GREET2   DC    C'TYPE A LINE AND PRESS ENTER.  TYPE BYE TO FINISH.'
PROMPT   DC    C'> '
FAREWELL DC    C'ASYPOCB SIGNING OFF.  GOODBYE.'
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
TXTADDR  DS    F
TXTLEN   DS    F
F15      DC    F'15'
F3       DC    F'3'
RETCODE  DC    X'00'
XLATE    DC    C'Y'                Y = THIS PROGRAM TRANSLATES
ADDEOL   DC    C'Y'
HEXOUT   DC    CL46' '
BLANKS   DC    CL46' '
HEXTAB   DC    C'0123456789ABCDEF'
         SPACE 2
*---------------------------------------------------------------------*
*   M E S S A G E S   -  ALL PADDED TO 62 BYTES                       *
*---------------------------------------------------------------------*
MSG010   DC    CL62'ASYPOCB 010 OPENING BTAM LINE GROUP - DD TTYLINE'
MSG012   DC    CL62'ASYPOCB 012 OPEN FAILED - LOOK FOR AN IEC MESSAGE'
MSG015   DC    CL62'ASYPOCB 015 LINE GROUP IS OPEN'
MSG030   DC    CL62'ASYPOCB 030 GREETING SENT - WAITING FOR INPUT'
MSG040   DC    CL62'ASYPOCB 040 LINE RECEIVED - TEXT FOLLOWS'
MSG050   DC    CL62'ASYPOCB 050 BYE RECEIVED - ENDING THE SESSION'
MSG060   DC    CL62'ASYPOCB 060 TURN LIMIT REACHED - ENDING'
MSG070   DC    CL62'ASYPOCB 070 TRANSLATION ON - THIS PROGRAM CONVERTS'
MSG072   DC    CL62'ASYPOCB 072 TRANSLATION OFF - BYTES PASS THROUGH'
MSG910   DC    CL62'ASYPOCB 910 BTAM DID NOT POST NORMAL - DECB BELOW'
MSG920   DC    CL62'ASYPOCB 920 DECB AFTER THE READ'
MSG980   DC    CL62'ASYPOCB 980 READ RETURNED NO USABLE DATA'
MSG992   DC    CL62'ASYPOCB 992 BTAM POSTED AN ERROR - SEE ABOVE'
MSG999   DC    CL62'ASYPOCB 999 ENDING'
MSGHEX   DC    CL62'ASYPOCB 900 HEX='
MSGTXTP  DC    CL62'ASYPOCB 900 TXT='
         SPACE 2
*---------------------------------------------------------------------*
*   T R A N S L A T E   T A B L E S                                   *
*                                                                     *
*   CARRIED OVER FROM ASYPOC UNCHANGED.  GENERATED FROM CODE PAGE 037 *
*   AND THEN BIT REVERSED , BECAUSE A START STOP LINE SHIFTS EACH     *
*   CHARACTER OUT LOW ORDER BIT FIRST.  MEASURED ON THE WIRE , NOT    *
*   GUESSED AT.  ASC2EBC IS INDEXED BY THE WIRE BYTE AND MASKS OFF    *
*   THE EVEN PARITY BIT , WHICH LANDS IN BIT 0 AFTER REVERSAL.        *
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
         END   ASYPOCB
