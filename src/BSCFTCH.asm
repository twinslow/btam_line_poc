*---------------------------------------------------------------------*
*                                                                     *
*   B S C F T C H  -  BSC FILE FETCH STARTED TASK                     *
*                                                                     *
*   STAGE 2 OF 4.  SEE DOCS/FETCH-DESIGN.MD.                          *
*                                                                     *
*   WHAT THIS STAGE DOES                                              *
*     1. TAKES THE MVS COMMAND INTERFACE SO IT CAN BE STOPPED         *
*     2. OPENS THE BSC LINE GROUP  (DDNAME BSCLINE)                   *
*     3. SENDS A HEL BLOCK AND LOOKS FOR A DAT00 REPLY                *
*     3A. WALKS THE VSAM CONTROL FILE AND FETCHES EACH FILE           *
*     4. CLOSES THE LINE                                              *
*     5. WAITS 15 SECONDS AND GOES ROUND AGAIN, UNTIL STOPPED         *
*                                                                     *
*   STAGE 2 ADDS THE VSAM CONTROL FILE AND THE GET CONVERSATION -     *
*   IT WALKS THE KSDS , FETCHES EACH IN PROGRESS FILE FROM THE        *
*   PARTNER , AND MARKS THE RECORD COMPLETE.                          *
*                                                                     *
*   WHAT IT DOES NOT DO YET - STAGE 3                                 *
*     - DYNALLOC OF THE TEMPORARY DATASET AND OF SYSOUT               *
*     - THE COPY TO JES2 FOR PRINTING                                 *
*   THE RETURNED LINES ARE COUNTED AND DISCARDED.  THE PLACE WHERE    *
*   THAT WORK GOES IS MARKED >>> STAGE 3 <<< .                        *
*                                                                     *
*   THE BSC CODING IS LIFTED FROM BSCPOCB , WHICH RUNS CORRECTLY ON   *
*   THIS SYSTEM.  OPERAND ORDER IS                                    *
*        DECB , TYPE , DCB , AREA , LENGTH , TERMLIST , LINENO        *
*   AND THE DECB LAYOUT IS  +0 ECB  +4 FLAGS  +5 TYPE  +6 LENGTH      *
*   +8 DCB  +12 AREA  +16 ERROR INFO  +20 TERMINAL LIST.  THAT IS WHY *
*   SENDBLK AND RECVBLK CAN PLANT A RUN TIME ADDRESS AND LENGTH INTO  *
*   AN OTHERWISE STATIC DECB.  BTAM DOES NOT FRAME THE BLOCK , SO THE *
*   BUFFER CARRIES ITS OWN STX AND ETX.                               *
*                                                                     *
*   ASSEMBLY NEEDS SYS1.AMODGEN ON SYSLIB AS WELL AS SYS1.MACLIB -    *
*   IEZCOM AND IEZCIB LIVE THERE.                                     *
*                                                                     *
*   THE CSECT NEEDS THREE BASE REGISTERS - R12 , R11 AND R10.  IF IT  *
*   GROWS PAST 12288 BYTES ANOTHER ONE HAS TO BE ADDED , WHICH SHOWS  *
*   UP AS  IFO209 ADDRESSABILITY ERROR  ON SCATTERED STATEMENTS.      *
*                                                                     *
*   THE COM AND CIB LAYOUT IS VERIFIED - JCL/COMMAC.JCL EXPANDED THE *
*   TWO MACROS ON THIS SYSTEM.  NOTE THAT NEITHER GENERATES A DSECT   *
*   OF ITS OWN ; THE DSECT CARDS AT THE BOTTOM OF THIS PROGRAM ARE    *
*   OURS , AS IEZCIB'S OWN COMMENTS INSTRUCT.                         *
*                                                                     *
*   STOP IT WITH THE MVS  P BSCFTCH  COMMAND.                         *
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
*   BSC CONTROL CHARACTERS (EBCDIC)
STX      EQU   X'02'
ETX      EQU   X'03'
ETB      EQU   X'26'
         SPACE 1
INLEN    EQU   256                 SIZE OF THE LINE INPUT BUFFER
HEXMAX   EQU   23                  BYTES SHOWN BY THE HEX DUMP
HEXLEN   EQU   46                  ... WHICH IS 46 PRINT POSITIONS
NORMAL   EQU   X'7F'               ECB POST CODE FOR NORMAL COMPLETION
         SPACE 1
*   DECB FIELD OFFSETS , TAKEN FROM A REAL EXPANSION ON THIS SYSTEM
DECBLEN  EQU   6                   HALFWORD LENGTH
DECBAREA EQU   12                  FULLWORD AREA ADDRESS
DECBLNG  EQU   40                  WHOLE DECB
         SPACE 1
*   MESSAGE LAYOUT - 3 BYTE ID , 2 BYTE STATUS , THEN DATA
MIDLEN   EQU   3
STATLEN  EQU   2
HDRLEN   EQU   5                   MIDLEN + STATLEN
         SPACE 1
CTLRECL  EQU   60                  CONTROL RECORD LENGTH
CTLKEYL  EQU   30                  ... OF WHICH THIS MUCH IS THE KEY
STATINPR EQU   C'I'                IN PROGRESS - PROCESS THIS ONE
STATDONE EQU   C'C'                COMPLETE
STATDEL  EQU   C'D'                LOGICALLY DELETED
FBEOD    EQU   X'04'               VSAM FEEDBACK - END OF DATA
         SPACE 1
IOTIMLV  EQU   3000                30 SECONDS , IN 1/100 SECOND UNITS
*                                  FOR OPERATIONS THAT WAIT ON THE
*                                  PARTNER - IT HAS TO OPEN A FILE AND
*                                  START SENDING
IOTIMSV  EQU   500                 5 SECONDS , FOR BIDS.  A BID ON A
*                                  HEALTHY LINE TAKES MILLISECONDS , SO
*                                  A DEAD LINE IS FOUND QUICKLY RATHER
*                                  THAN COSTING 30 SECONDS A CYCLE
         SPACE 1
ONESEC   EQU   100                 STIMER UNITS ARE 1/100 SECOND
NAPSLICE EQU   15                  HOW MANY ONE SECOND SLICES WE WAIT
*                                  KEEP MSG050 IN STEP WITH THIS
         EJECT
BSCFTCH  CSECT
         STM   R14,R12,12(R13)     SAVE CALLERS REGISTERS
         LR    R12,R15             LOAD OUR FIRST BASE
         USING BSCFTCH,R12,R11,R10
         SPACE 1
*   THREE BASE REGISTERS.  THE CSECT IS WELL PAST 4096 BYTES - THE
*   MESSAGES AND THE TWO 256 BYTE LINE BUFFERS ALONE ACCOUNT FOR MOST
*   OF IT - AND ONE BASE ONLY COVERS 4096.  R11 AND R10 CARRY ON FROM
*   R12.  NOTHING BETWEEN THE USING AND THESE FOUR INSTRUCTIONS MAY
*   REFER TO A SYMBOL , BECAUSE R11 AND R10 ARE NOT LOADED YET.
         SPACE 1
         LA    R11,4095(,R12)
         LA    R11,1(,R11)         SECOND BASE = FIRST + 4096
         LA    R10,4095(,R11)
         LA    R10,1(,R10)         THIRD BASE  = FIRST + 8192
         SPACE 1
         LA    R2,SAVEAREA
         ST    R13,4(R2)           BACKWARD CHAIN
         ST    R2,8(R13)           FORWARD CHAIN
         LR    R13,R2
         MVI   STOPFLAG,C'N'
         SPACE 1
         LA    R1,MSG010
         BAL   R14,SAY
         SPACE 1
*---------------------------------------------------------------------*
*   TAKE THE COMMAND INTERFACE.                                       *
*                                                                     *
*   EXTRACT GIVES US THE ADDRESS OF THE COMMUNICATIONS AREA.  THE     *
*   FIRST CIB ON THE CHAIN IS THE START CIB , WHICH WE FREE.  QEDIT   *
*   WITH CIBCTR=1 THEN LETS ONE COMMAND QUEUE UP , WHICH IS ALL WE    *
*   NEED FOR STOP.                                                    *
*                                                                     *
*   NOTE - ORIGIN MUST NOT BE REGISTER 1 ; THE MACRO BUILDS ITS OWN   *
*   PARAMETER LIST THERE.  THE PROBE SAID SO IN SO MANY WORDS.        *
*---------------------------------------------------------------------*
         EXTRACT COMPTR,'S',FIELDS=(COMM)
         L     R2,COMPTR
         LTR   R2,R2
         BZ    NOCOMM              NOT A STARTED TASK - CARRY ON
         USING COMAREA,R2
         ICM   R3,15,COMCIBPT      THE START CIB
         BZ    SETCTR
         QEDIT ORIGIN=COMCIBPT,BLOCK=(R3)      FREE IT
SETCTR   QEDIT ORIGIN=COMCIBPT,CIBCTR=1        ALLOW ONE COMMAND
         DROP  R2
         LA    R1,MSG012
         BAL   R14,SAY
         B     COMMOK
NOCOMM   LA    R1,MSG014
         BAL   R14,SAY
COMMOK   EQU   *
         EJECT
*---------------------------------------------------------------------*
*   T H E   M A I N   C Y C L E                                       *
*---------------------------------------------------------------------*
MAINLOOP EQU   *
         CLI   STOPFLAG,C'Y'
         BE    SHUTDOWN
         SPACE 1
         LA    R1,MSG020
         BAL   R14,SAY
         OPEN  (LINEDCB,(INPUT))
         TM    LINEDCB+48,X'10'    DCBOFLGS - DID THE OPEN WORK ?
         BO    LINEOPEN
         LA    R1,MSG022
         BAL   R14,SAY
         B     NAPTIME             LEAVE IT AND TRY AGAIN LATER
LINEOPEN EQU   *
         LA    R1,MSG024
         BAL   R14,SAY
         BAL   R14,CHKLERB         SILENT UNLESS THE LERB OVERRAN
         SPACE 1
*---------------------------------------------------------------------*
*   SAY HELLO.  ONE TRANSMISSION OUT - BID , THE HEL BLOCK , EOT -    *
*   THEN ONE TRANSMISSION IN.                                         *
*---------------------------------------------------------------------*
         LA    R1,HELBLK
         LA    R0,HELBLKL
         BAL   R14,SENDBLK
         LTR   R15,R15
         BNZ   LINEBAD
         BAL   R14,SENDEOT
         LTR   R15,R15
         BNZ   LINEBAD
         SPACE 1
         LA    R1,MSG030
         BAL   R14,SAY
         BAL   R14,RECVBLK
         LTR   R15,R15
         BNZ   LINEBAD
         SPACE 1
*        R1 -> THE MESSAGE ID , R0 = LENGTH FROM THERE.  SAVE BEFORE
*        ANYTHING ISSUES A WTO - WTO DESTROYS R0 R1 AND R15.
         ST    R1,MSGADDR
         ST    R0,MSGLEN
         BAL   R14,SHOWMSG
         SPACE 1
         L     R1,MSGADDR
         CLC   0(MIDLEN,R1),IDDAT  DID WE GET A DAT REPLY ?
         BNE   BADREPLY
         CLC   MIDLEN(STATLEN,R1),ST00
         BNE   BADREPLY
         LA    R1,MSG034
         BAL   R14,SAY
         SPACE 1
*        SWALLOW THE PARTNERS EOT SO THE LINE IS CLEAN.
         BAL   R14,RECVEOT
         SPACE 1
*---------------------------------------------------------------------*
*   THE PROCESS LOOP - WALK THE CONTROL FILE AND FETCH EVERY FILE     *
*   THAT IS STILL MARKED IN PROGRESS.                                 *
*                                                                     *
*   >>> STAGE 3 <<<  THE RETURNED DATA IS COUNTED AND DISCARDED FOR   *
*   NOW.  DYNALLOC OF THE TEMPORARY DATASET AND OF SYSOUT , AND THE   *
*   COPY TO JES2 , IS THE NEXT STAGE.                                 *
*---------------------------------------------------------------------*
         BAL   R14,PROCESS
         B     LINEDONE
         SPACE 1
BADREPLY LA    R1,MSG032
         BAL   R14,SAY
         B     LINEDONE
LINEBAD  LA    R1,MSG036
         BAL   R14,SAY
LINEDONE EQU   *
         CLOSE (LINEDCB)
         LA    R1,MSG050
         BAL   R14,SAY
         SPACE 1
NAPTIME  BAL   R14,NAPWAIT
         B     MAINLOOP
         SPACE 1
SHUTDOWN LA    R1,MSG900
         BAL   R14,SAY
RETURN   EQU   *
         SR    R15,R15
         L     R13,4(R13)
         ST    R15,16(R13)
         LM    R14,R12,12(R13)
         BR    R14
         EJECT
*---------------------------------------------------------------------*
*   C H K L E R B  -  CHECK THE LERB FENCE AFTER OPEN                 *
*                                                                     *
*   THIS USED TO DUMP THE LERB AS WELL , TO SEE WHETHER A FAILED      *
*   ENABLE LEFT A SIGNATURE WE COULD TEST FOR.  IT DOES NOT.  TWO     *
*   CYCLES WERE OBSERVED WITH BYTE FOR BYTE IDENTICAL LERBS , ONE OF  *
*   WHICH THEN FAILED AND ONE OF WHICH SUCCEEDED.  THE LERB HOLDS     *
*   CUMULATIVE COUNTERS - ONE ROSE BY FOUR ON EVERY GOOD CYCLE ,      *
*   MATCHING THE FOUR BTAM OPERATIONS A CYCLE PERFORMS - SO READ AT   *
*   OPEN TIME IT DESCRIBES THE PREVIOUS CYCLE , NOT THIS ONE.         *
*                                                                     *
*   THE BID TIMEOUT IN IOWAITS IS WHAT DETECTS A DEAD LINE.  ALL      *
*   THAT IS LEFT HERE IS THE FENCE CHECK , WHICH IS SILENT UNLESS     *
*   BTAM HAS WRITTEN PAST THE 64 BYTES WE GAVE IT.                    *
*---------------------------------------------------------------------*
CHKLERB  ST    R14,SLBSAVE
         CLC   LERBFNCE,LERBEYE
         BE    SLBOK
         LA    R1,MSG162
         BAL   R14,SAY
         LA    R1,MSG164
         BAL   R14,SAY
         LA    R1,LERBFNCE
         LA    R0,L'LERBFNCE
         BAL   R14,DUMPHEX
SLBOK    L     R14,SLBSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   N A P W A I T  -  WAIT NAPSLICE SECONDS BETWEEN CYCLES , TAKEN IN *
*   ONE SECOND SLICES SO THAT A STOP COMMAND IS NOTICED WITHIN ABOUT  *
*   A SECOND RATHER THAN AT THE END OF THE WAIT.  STIMER WAIT CANNOT  *
*   BE INTERRUPTED , WHICH IS WHY THIS IS A LOOP AND NOT ONE CALL.    *
*   RETURNS EARLY ONCE STOPPED.                                       *
*---------------------------------------------------------------------*
NAPWAIT  ST    R14,NAPSAVE
         LA    R6,NAPSLICE
NAPLOOP  BAL   R14,CHKSTOP
         CLI   STOPFLAG,C'Y'
         BE    NAPEND
         STIMER WAIT,BINTVL=ONESECX
         BCT   R6,NAPLOOP
NAPEND   L     R14,NAPSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   C H K S T O P  -  LOOK FOR A QUEUED COMMAND.  A STOP SETS THE     *
*   FLAG ; ANYTHING ELSE IS ACKNOWLEDGED AND DISCARDED.  EITHER WAY   *
*   THE CIB IS FREED SO THE NEXT COMMAND CAN QUEUE.                   *
*---------------------------------------------------------------------*
CHKSTOP  ST    R14,STPSAVE
         L     R2,COMPTR
         LTR   R2,R2
         BZ    STPEND              NO COMMAND INTERFACE AT ALL
         USING COMAREA,R2
         ICM   R3,15,COMCIBPT
         BZ    STPEND              NOTHING QUEUED
         USING CIBAREA,R3
         CLI   CIBVERB,CIBSTOP
         BNE   STPOTHER
         MVI   STOPFLAG,C'Y'
         QEDIT ORIGIN=COMCIBPT,BLOCK=(R3)
         DROP  R2,R3
         LA    R1,MSG910
         BAL   R14,SAY
         B     STPEND
STPOTHER EQU   *
         USING COMAREA,R2
         USING CIBAREA,R3
         QEDIT ORIGIN=COMCIBPT,BLOCK=(R3)
         DROP  R2,R3
         LA    R1,MSG912
         BAL   R14,SAY
STPEND   L     R14,STPSAVE
         BR    R14
         EJECT
*---------------------------------------------------------------------*
*   I O W A I T  -  WAIT FOR A BTAM OPERATION , BUT NOT FOR EVER      *
*                                                                     *
*   TWAIT HAS NO TIMEOUT , AND THERE IS A STATE THIS LINE GETS INTO   *
*   WHERE WAITING IS HOPELESS.  IF THE ENABLE FAILS DURING OPEN -     *
*   COMMADPT PLACES AN OUTGOING CALL THERE AND IT CAN BE REFUSED -    *
*   OPEN STILL SETS DCBOFLGS , BUT BTAM THEN ACCEPTS THE WRITE AND    *
*   NEVER STARTS A CHANNEL PROGRAM AT ALL.  THE HERCULES TRACE SHOWS  *
*   NO CCW AFTER THE OPEN.  NOTHING WILL EVER POST THAT ECB , SO      *
*   TWAIT SITS THERE UNTIL THE JOB WAIT LIMIT AND ONLY A CANCEL GETS  *
*   THE TASK BACK.                                                    *
*                                                                     *
*   SO WAIT ON THE OPERATION ECB AND A TIMER ECB TOGETHER.  IF THE    *
*   TIMER WINS THE CYCLE IS ABANDONED , THE LINE IS CLOSED AND THE    *
*   NEXT CYCLE STARTS FRESH - WHICH IS WHAT MAKES IT RECOVER ON ITS   *
*   OWN ONCE THE PARTNER COMES BACK.                                  *
*                                                                     *
*   ENTRY R1 = DECB ADDRESS (ITS FIRST WORD IS THE ECB)               *
*   EXIT  R15 = 0 POSTED NORMALLY / 4 GAVE UP WAITING                 *
*---------------------------------------------------------------------*
*   TWO ENTRY POINTS.  IOWAITS IS FOR BIDS , WHICH ARE QUICK ON A
*   HEALTHY LINE ; IOWAIT IS FOR OPERATIONS THAT WAIT ON THE PARTNER.
*   R14 IS UNTOUCHED BY THE MVC AND THE BRANCH , SO IT IS STILL THE
*   CALLERS RETURN ADDRESS WHEN IOWGO SAVES IT.
         SPACE 1
IOWAITS  MVC   IOTIMEA,IOTIMES     SHORT LIMIT
         B     IOWGO
IOWAIT   MVC   IOTIMEA,IOTIMEL     NORMAL LIMIT
IOWGO    ST    R14,IOWSAVE
         ST    R1,WAITLST          FIRST ENTRY - THE OPERATION ECB
         XC    TIMERECB,TIMERECB
         LA    R1,TIMERECB
         O     R1,HIBIT            HIGH BIT MARKS THE LAST ENTRY
         ST    R1,WAITLST+4
         STIMER REAL,TIMEXIT,BINTVL=IOTIMEA
         WAIT  1,ECBLIST=WAITLST
         TM    TIMERECB,X'40'      DID THE TIMER GET THERE FIRST ?
         BO    IOWLATE
         TTIMER CANCEL             NO - STAND THE TIMER DOWN
         SR    R15,R15
         B     IOWEND
IOWLATE  LA    R1,MSG940
         BAL   R14,SAY
         LA    R15,4
IOWEND   L     R14,IOWSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   T I M E X I T  -  STIMER EXIT , POSTS THE TIMER ECB               *
*                                                                     *
*   RUNS ASYNCHRONOUSLY UNDER AN IRB.  IT CANNOT USE THE PROGRAM BASE *
*   REGISTERS , SO IT ESTABLISHES ITS OWN FROM R15 AND PICKS THE ECB  *
*   ADDRESS OUT OF A CONSTANT SITTING RIGHT BEHIND IT.                *
*---------------------------------------------------------------------*
TIMEXIT  SAVE  (14,12)
         LR    R12,R15             R15 = OUR OWN ENTRY POINT
         USING TIMEXIT,R12
         L     R2,TXECBP
         POST  (R2)
         RETURN (14,12)
TXECBP   DC    A(TIMERECB)
         SPACE 1
*        PUT THE PROGRAM BASES BACK.  THE USING ABOVE OVERRODE R12 FOR
*        THE EXIT , AND DROPPING IT WITHOUT RESTORING LEAVES THE REST
*        OF THE PROGRAM WITH ONLY R11 AND R10 - SO EVERYTHING IN THE
*        FIRST 4096 BYTES BECOMES UNADDRESSABLE.  THAT LOOKS LIKE A
*        SIZE PROBLEM IN THE DIAGNOSTICS AND IS NOT ONE.
         SPACE 1
         DROP  R12
         USING BSCFTCH,R12,R11,R10
         SPACE 2
*---------------------------------------------------------------------*
*   S E N D B L K  -  BID FOR THE LINE AND SEND ONE TEXT BLOCK        *
*                                                                     *
*   WRITE TI DOES THE WHOLE BID - ENQ , ACK0 , THE BLOCK , ACK1 -     *
*   WHICH BSCPOCB CONFIRMED ON THE WIRE.                              *
*                                                                     *
*   ENTRY R1 = BLOCK ADDRESS , R0 = LENGTH.  EXIT R15 = 0 OK / 8 BAD. *
*---------------------------------------------------------------------*
SENDBLK  ST    R14,SNDSAVE
         ST    R1,WDECB+DECBAREA
         STH   R0,WDECB+DECBLEN
         XC    WDECB(4),WDECB      CLEAR THE ECB - THE MACRO DOES NOT
         WRITE WDECB,TI,LINEDCB,OUTAREA,1,TRMLST,1
         LA    R1,WDECB
         BAL   R14,IOWAITS         A BID SHOULD BE QUICK
         LTR   R15,R15
         BNZ   SNDBAD              GAVE UP - MESSAGE ALREADY ISSUED
         CLI   WDECB,NORMAL
         BE    SNDOK
         LA    R1,MSG920
         BAL   R14,SAY
         LA    R1,WDECB
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
SNDBAD   LA    R15,8
         B     SNDEND
SNDOK    SR    R15,R15
SNDEND   L     R14,SNDSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   S E N D E O T  -  END OUR TRANSMISSION.  THE AREA AND LENGTH ARE  *
*   NOT MEANINGFUL BUT THE MACRO WANTS THEM.                          *
*---------------------------------------------------------------------*
SENDEOT  ST    R14,EOTSAVE
         XC    EDECB(4),EDECB
         WRITE EDECB,TR,LINEDCB,OUTAREA,1,TRMLST,1
         LA    R1,EDECB
         BAL   R14,IOWAITS         SO SHOULD AN EOT
         LTR   R15,R15
         BNZ   EOTBAD              GAVE UP - MESSAGE ALREADY ISSUED
         CLI   EDECB,NORMAL
         BE    EOTOK
         LA    R1,MSG922
         BAL   R14,SAY
EOTBAD   LA    R15,8
         B     EOTEND
EOTOK    SR    R15,R15
EOTEND   L     R14,EOTSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   R E C V B L K  -  TAKE THE PARTNERS BID AND ONE TEXT BLOCK        *
*                                                                     *
*   BTAM ANSWERS THE ENQ WITH ACK0 AND ACKNOWLEDGES THE BLOCK ITSELF. *
*   THE BUFFER IS CLEARED FIRST AND THE LENGTH FOUND BY SCANNING FOR  *
*   THE ETX OR ETB , BECAUSE WE STILL DO NOT KNOW WHERE BTAM POSTS    *
*   THE RECEIVED COUNT.  THE DECB IS DUMPED SO IT CAN BE FOUND.       *
*                                                                     *
*   EXIT R1 -> THE MESSAGE ID , R0 = LENGTH FROM THERE                *
*        R15 = 0 OK / 4 NOTHING USABLE / 8 BTAM ERROR                 *
*---------------------------------------------------------------------*
RECVBLK  ST    R14,RCVSAVE
         BAL   R14,RDPREP
         LA    R1,INAREA
         ST    R1,RDECB+DECBAREA
         LA    R0,INLEN
         STH   R0,RDECB+DECBLEN
         XC    RDECB(4),RDECB
         READ  RDECB,TI,LINEDCB,INAREA,1,TRMLST,1
         LA    R1,RDECB
         BAL   R14,IOWAIT
         LTR   R15,R15
         BNZ   RCVBAD              GAVE UP - MESSAGE ALREADY ISSUED
         CLI   RDECB,NORMAL
         BE    RCVPARS
         LA    R1,MSG924
         BAL   R14,SAY
         LA    R1,RDECB
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
RCVBAD   LA    R15,8
         B     RCVEND
RCVPARS  BAL   R14,PARSEBLK
RCVEND   L     R14,RCVSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   R E C V C O N T  -  TAKE A CONTINUATION BLOCK OF THE SAME         *
*   TRANSMISSION.  READ TI TOOK THE BID AND THE FIRST BLOCK ; EVERY   *
*   BLOCK AFTER THAT COMES BACK WITH READ TT.  THE CALLER KEEPS       *
*   GOING WHILE TERMCH IS ETB AND STOPS WHEN IT IS ETX.               *
*---------------------------------------------------------------------*
RECVCONT ST    R14,RCTSAVE
         BAL   R14,RDPREP
         LA    R1,INAREA
         ST    R1,CDECB+DECBAREA
         LA    R0,INLEN
         STH   R0,CDECB+DECBLEN
         XC    CDECB(4),CDECB
         READ  CDECB,TT,LINEDCB,INAREA,1,TRMLST,1
         LA    R1,CDECB
         BAL   R14,IOWAIT
         LTR   R15,R15
         BNZ   RCTBAD              GAVE UP - MESSAGE ALREADY ISSUED
         CLI   CDECB,NORMAL
         BE    RCTPARS
         LA    R1,MSG930
         BAL   R14,SAY
         LA    R1,CDECB
         LA    R0,HEXMAX
         BAL   R14,DUMPHEX
RCTBAD   LA    R15,8
         B     RCTEND
RCTPARS  BAL   R14,PARSEBLK
RCTEND   L     R14,RCTSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   R D P R E P  -  CLEAR THE INPUT BUFFER AHEAD OF A READ            *
*---------------------------------------------------------------------*
RDPREP   MVI   INAREA,X'00'
         MVC   INAREA+1(INLEN-1),INAREA
         MVI   TERMCH,X'00'
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   P A R S E B L K  -  FIND THE MESSAGE INSIDE THE BLOCK JUST READ   *
*                                                                     *
*   THE LENGTH IS FOUND BY SCANNING FOR THE TERMINATOR RATHER THAN    *
*   BY ASKING BTAM , BECAUSE WE STILL DO NOT KNOW WHERE IT POSTS THE  *
*   RECEIVED COUNT.  TERMCH IS LEFT HOLDING THE ETX OR ETB SO THE     *
*   CALLER CAN TELL WHETHER MORE BLOCKS FOLLOW.                       *
*                                                                     *
*   EXIT R1 -> THE MESSAGE ID , R0 = LENGTH , R15 = 0 OK / 4 EMPTY    *
*---------------------------------------------------------------------*
PARSEBLK ST    R14,PRSSAVE
         LA    R2,INAREA
         CLI   0(R2),STX
         BNE   PRSSCAN
         LA    R2,1(R2)
PRSSCAN  LR    R3,R2               R3 WALKS , R4 COUNTS
         SR    R4,R4
         LA    R5,INLEN
PRSNEXT  CLI   0(R3),ETX
         BE    PRSTERM
         CLI   0(R3),ETB
         BE    PRSTERM
         CLI   0(R3),X'00'         RAN OFF THE END OF THE DATA
         BE    PRSFOUND
         LA    R3,1(R3)
         LA    R4,1(R4)
         BCT   R5,PRSNEXT
         B     PRSFOUND
PRSTERM  MVC   TERMCH,0(R3)
PRSFOUND LR    R1,R2
         LR    R0,R4
         LTR   R4,R4
         BNP   PRSNONE
         SR    R15,R15
         B     PRSEND
PRSNONE  LA    R1,MSG928
         BAL   R14,SAY
         LA    R1,INAREA
         SR    R0,R0
         LA    R15,4
PRSEND   L     R14,PRSSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   R E C V E O T  -  PICK UP THE PARTNERS END OF TRANSMISSION.       *
*   A NON NORMAL POST IS NOT TREATED AS FATAL - BTAM MAY REPORT END   *
*   OF TRANSMISSION WITH A CODE OF ITS OWN.                           *
*---------------------------------------------------------------------*
RECVEOT  ST    R14,RETSAVE
         XC    TDECB(4),TDECB
         READ  TDECB,TT,LINEDCB,INAREA,INLEN,TRMLST,1
         LA    R1,TDECB
         BAL   R14,IOWAIT
         L     R14,RETSAVE
         BR    R14
         EJECT
*---------------------------------------------------------------------*
*   P R O C E S S  -  WALK THE CONTROL FILE                           *
*                                                                     *
*   OPEN THE KSDS , READ IT SEQUENTIALLY , AND FOR EVERY RECORD STILL *
*   MARKED IN PROGRESS FETCH THE NAMED FILE FROM THE PARTNER.  A      *
*   RECORD IS ONLY MARKED COMPLETE ONCE ITS FILE HAS ARRIVED IN FULL, *
*   SO A FAILURE LEAVES IT FOR THE NEXT CYCLE.                        *
*                                                                     *
*   THE RPL IS OPTCD=(KEY,SEQ,UPD) , SO EACH GET HOLDS THE RECORD FOR *
*   UPDATE AND A PUT ON THE SAME RPL REWRITES IT IN PLACE.            *
*---------------------------------------------------------------------*
PROCESS  ST    R14,PRCSAVE
         XC    RECCOUNT,RECCOUNT
         XC    DONECNT,DONECNT
         XC    ERRCNT,ERRCNT
         LA    R1,MSG100
         BAL   R14,SAY
         OPEN  (CTLACB)
         LTR   R15,R15
         BZ    PRCLOOP
         BAL   R14,ACBERR
         B     PRCEND
PRCLOOP  BAL   R14,GETNEXT
         LTR   R15,R15
         BNZ   PRCDONE             4 = END OF FILE , 8 = ERROR
         L     R1,RECCOUNT
         LA    R1,1(R1)
         ST    R1,RECCOUNT
         CLI   CTLSTAT,STATINPR    ONLY IN PROGRESS RECORDS
         BNE   PRCLOOP
         BAL   R14,SHOWKEY
         BAL   R14,GETFILE
         LTR   R15,R15
         BNZ   PRCERR              THE FETCH FAILED
         MVI   CTLSTAT,STATDONE
         BAL   R14,UPDCTL
         LTR   R15,R15
         BNZ   PRCERR              THE FILE CAME BUT THE UPDATE DID NOT
         L     R1,DONECNT
         LA    R1,1(R1)
         ST    R1,DONECNT
         B     PRCLOOP
         SPACE 1
*        A RECORD WE TRIED AND COULD NOT FINISH.  IT IS LEFT AT I SO
*        THE NEXT CYCLE PICKS IT UP AGAIN , AND COUNTED SO THE TOTALS
*        ADD UP - EVERY IN PROGRESS RECORD ENDS UP EITHER COMPLETE OR
*        IN THIS COUNT.
         SPACE 1
PRCERR   L     R1,ERRCNT
         LA    R1,1(R1)
         ST    R1,ERRCNT
         B     PRCLOOP
PRCDONE  CLOSE (CTLACB)
         LA    R1,MSGREC
         L     R0,RECCOUNT
         BAL   R14,SHOWNUM
         LA    R1,MSGDONE
         L     R0,DONECNT
         BAL   R14,SHOWNUM
         LA    R1,MSGERRS
         L     R0,ERRCNT
         BAL   R14,SHOWNUM
PRCEND   L     R14,PRCSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   G E T N E X T  -  SEQUENTIAL GET FROM THE CONTROL FILE            *
*   EXIT R15 = 0 GOT ONE / 4 END OF FILE / 8 ERROR                    *
*---------------------------------------------------------------------*
GETNEXT  ST    R14,GNXSAVE
         GET   RPL=CTLRPL
         LTR   R15,R15
         BZ    GNXOK
         BAL   R14,GETFDBK
         CLI   FDBKC,FBEOD         PLAIN END OF DATA ?
         BNE   GNXBAD
         LA    R15,4
         B     GNXEND
GNXBAD   LA    R1,MSG104
         BAL   R14,SAY
         BAL   R14,SHOWFDBK
         LA    R15,8
         B     GNXEND
GNXOK    SR    R15,R15
GNXEND   L     R14,GNXSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   U P D C T L  -  REWRITE THE RECORD JUST READ                      *
*---------------------------------------------------------------------*
UPDCTL   ST    R14,UPDSAVE
         PUT   RPL=CTLRPL
         LTR   R15,R15
         BZ    UPDOK
         LA    R1,MSG110
         BAL   R14,SAY
         BAL   R14,GETFDBK
         BAL   R14,SHOWFDBK
         LA    R15,8
         B     UPDEND
UPDOK    LA    R1,MSG112
         BAL   R14,SAY
         SR    R15,R15
UPDEND   L     R14,UPDSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   G E T F D B K  -  PULL THE RPL FEEDBACK CODE OUT WITH SHOWCB      *
*   A C B E R R   -  REPORT AN ACB OPEN FAILURE                       *
*   S H O W F D B K - WTO THE FEEDBACK WORD IN HEX                    *
*---------------------------------------------------------------------*
GETFDBK  ST    R14,FDBSAVE
         XC    FDBKW,FDBKW
         SHOWCB RPL=CTLRPL,AREA=FDBKW,LENGTH=4,FIELDS=(FDBK)
         L     R14,FDBSAVE
         BR    R14
         SPACE 1
ACBERR   ST    R14,ACBSAVE
         LA    R1,MSG102
         BAL   R14,SAY
         XC    FDBKW,FDBKW
         SHOWCB ACB=CTLACB,AREA=FDBKW,LENGTH=4,FIELDS=(ERROR)
         BAL   R14,SHOWFDBK
         L     R14,ACBSAVE
         BR    R14
         SPACE 1
SHOWFDBK ST    R14,SFBSAVE
         LA    R1,FDBKW
         LA    R0,4
         BAL   R14,DUMPHEX
         L     R14,SFBSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   G E T F I L E  -  FETCH ONE FILE FROM THE PARTNER                 *
*                                                                     *
*   SENDS  GET00<KEY>  AS ITS OWN TRANSMISSION , THEN READS THE       *
*   PARTNERS REPLY - DAT BLOCKS UNTIL EOF , OR A SINGLE ERR.  BLOCKS  *
*   TERMINATED WITH ETB HAVE MORE TO FOLLOW ; ETX ENDS IT.            *
*                                                                     *
*   >>> STAGE 3 <<<  EACH DAT LINE IS COUNTED AND THROWN AWAY.  THIS  *
*   IS WHERE THE WRITE TO THE TEMPORARY DATASET WILL GO.              *
*                                                                     *
*   EXIT R15 = 0 THE WHOLE FILE ARRIVED / 8 IT DID NOT                *
*---------------------------------------------------------------------*
GETFILE  ST    R14,GTFSAVE
         MVC   GETKEY,CTLKEY
         XC    LINECNT,LINECNT
         LA    R1,GETBLK
         LA    R0,GETBLKL
         BAL   R14,SENDBLK
         LTR   R15,R15
         BNZ   GTFBAD
         BAL   R14,SENDEOT
         LTR   R15,R15
         BNZ   GTFBAD
         SPACE 1
         BAL   R14,RECVBLK
         B     GTFCHK
GTFMORE  BAL   R14,RECVCONT
GTFCHK   LTR   R15,R15
         BNZ   GTFBAD
         ST    R1,MSGADDR
         ST    R0,MSGLEN
         CLC   0(MIDLEN,R1),IDDAT
         BE    GTFDATA
         CLC   0(MIDLEN,R1),IDEOF
         BE    GTFEOF
         CLC   0(MIDLEN,R1),IDERR
         BE    GTFERR
         LA    R1,MSG120
         BAL   R14,SAY
         BAL   R14,SHOWMSG
         B     GTFDRAIN
GTFDATA  L     R1,LINECNT
         LA    R1,1(R1)
         ST    R1,LINECNT
         CLI   TERMCH,ETX          WAS THAT THE LAST BLOCK ?
         BE    GTFSHORT
         B     GTFMORE
GTFEOF   BAL   R14,RECVEOT
         LA    R1,MSGLINES
         L     R0,LINECNT
         BAL   R14,SHOWNUM
         SR    R15,R15
         B     GTFEND
GTFERR   LA    R1,MSG122
         BAL   R14,SAY
         BAL   R14,SHOWMSG
         B     GTFDRAIN
GTFSHORT LA    R1,MSG124           ETX BUT NO EOF BLOCK CAME
         BAL   R14,SAY
GTFDRAIN BAL   R14,RECVEOT
GTFBAD   LA    R15,8
GTFEND   L     R14,GTFSAVE
         BR    R14
         SPACE 2
*---------------------------------------------------------------------*
*   S H O W K E Y  -  WTO THE KEY OF THE RECORD BEING PROCESSED       *
*   S H O W N U M  -  WTO A MESSAGE WITH A NUMBER ON THE END          *
*                     ENTRY R1 = MESSAGE , R0 = VALUE                 *
*---------------------------------------------------------------------*
SHOWKEY  ST    R14,SKYSAVE
         MVC   MSGTEXT,MSGKEY
         MVC   MSGTEXT+16(CTLKEYL),CTLKEY
         WTO   MF=(E,MSGWTO)
         L     R14,SKYSAVE
         BR    R14
         SPACE 1
*        THE NUMBER LANDS AT +40 , SO A MESSAGE PASSED HERE MUST BE
*        40 CHARACTERS OR LESS OR THE COUNT EATS THE END OF THE TEXT.
SHOWNUM  ST    R14,SNMSAVE
         MVC   MSGTEXT,0(R1)
         CVD   R0,DWORD
         UNPK  NUMBUF,DWORD+4(4)
         OI    NUMBUF+7,X'F0'      FIX THE SIGN NIBBLE
         MVC   MSGTEXT+40(8),NUMBUF
         WTO   MF=(E,MSGWTO)
         L     R14,SNMSAVE
         BR    R14
         EJECT
*---------------------------------------------------------------------*
*   S H O W M S G  -  WTO THE MESSAGE ID , STATUS AND DATA            *
*---------------------------------------------------------------------*
SHOWMSG  ST    R14,SHWSAVE
         MVC   MSGTEXT,MSGRECV
         L     R7,MSGLEN
         LTR   R7,R7
         BNP   SHWOUT
         LA    R9,TXTMAX
         CR    R7,R9
         BNH   SHWMOVE
         LR    R7,R9
SHWMOVE  L     R6,MSGADDR
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
*   DEVD=BS AND THE REST ARE AS PROVEN BY BSCPOCB.  EROPT IS NOT      *
*   CODED - CODING IT DRAWS IHB050 , LEAVING IT OFF PRESETS IT TO C.  *
*---------------------------------------------------------------------*
LINEDCB  DCB   DSORG=CX,MACRF=(R,W),DEVD=BS,DDNAME=BSCLINE,            X
               BFTEK=S,LERB=LERBLK
         SPACE 1
TRMLST   DFTRMLST OPENLST,(0000)
         SPACE 1
         SPACE 2
*---------------------------------------------------------------------*
*   B U F F E R S   A N D   C O N S T A N T S                         *
*---------------------------------------------------------------------*
         DS    0F
INAREA   DS    CL256
         DS    0F
OUTAREA  DS    CL256
         DS    0F
*---------------------------------------------------------------------*
*   L E R B  -  BTAM LOGICAL ERROR RECORDING BLOCK                    *
*                                                                     *
*   >>> THE LENGTH HERE IS A GUESS <<<  IT WAS 16 BYTES , WHICH WAS   *
*   NOT TAKEN FROM ANYWHERE - AND HELBLK USED TO SIT IMMEDIATELY      *
*   BEHIND IT.  IF BTAM WRITES MORE THAN 16 BYTES ON A LINE ERROR IT  *
*   WOULD HAVE CORRUPTED THE HELLO BLOCK WE TRANSMIT , AND A LINE     *
*   ERROR IS PRECISELY WHEN THAT WOULD HAPPEN.                        *
*                                                                     *
*   PADDED TO 64 BYTES AND FENCED SO AN OVERRUN IS VISIBLE RATHER     *
*   THAN SILENT.  THE REAL LENGTH IS IN GC27-6980 ; ONCE IT IS KNOWN  *
*   THIS CAN BE SIZED PROPERLY.                                       *
*---------------------------------------------------------------------*
         DS    0F
LERBLK   DC    XL64'00'
LERBFNCE DC    C'*LERBEND*'        IF THIS IS EVER OVERWRITTEN , THE
*                                  LERB IS BIGGER THAN 64 BYTES
         SPACE 1
*   THE HELLO BLOCK - STX , ID , STATUS , ETX
         DS    0F
HELBLK   DC    X'02'
         DC    C'HEL'
         DC    C'00'
         DC    X'03'
HELBLKE  EQU   *
HELBLKL  EQU   HELBLKE-HELBLK
         SPACE 1
*   THE GET BLOCK - STX , ID , STATUS , THE 30 BYTE KEY , ETX
         DS    0F
GETBLK   DC    X'02'
         DC    C'GET'
         DC    C'00'
GETKEY   DC    CL30' '
         DC    X'03'
GETBLKE  EQU   *
GETBLKL  EQU   GETBLKE-GETBLK
         SPACE 2
*---------------------------------------------------------------------*
*   T H E   C O N T R O L   F I L E                                   *
*                                                                     *
*   KSDS , 30 BYTE KEY AT OFFSET 0 , 60 BYTE RECORD.  MACRF NEEDS OUT *
*   AS WELL AS IN BECAUSE WE REWRITE RECORDS IN PLACE ; OPTCD UPD ON  *
*   THE RPL IS WHAT MAKES EACH GET HOLD THE RECORD FOR THAT PUT.      *
*   MVE ASKS FOR THE RECORD TO BE MOVED INTO CTLREC RATHER THAN       *
*   LEAVING US A POINTER.                                             *
*---------------------------------------------------------------------*
         DS    0F
CTLACB   ACB   AM=VSAM,DDNAME=CTLFILE,MACRF=(KEY,SEQ,IN,OUT)
         SPACE 1
         DS    0F
CTLRPL   RPL   ACB=CTLACB,AM=VSAM,AREA=CTLREC,AREALEN=CTLRECL,         X
               OPTCD=(KEY,SEQ,UPD,MVE)
         SPACE 1
         DS    0F
CTLREC   DS    0CL60
CTLKEY   DS    CL30                THE FILE ID WE ASK THE PARTNER FOR
CTLSTAT  DS    CL1                 I IN PROGRESS  C COMPLETE  D DELETED
CTLRSVD  DS    CL29                RESERVED
         SPACE 2
IDDAT    DC    C'DAT'
IDEOF    DC    C'EOF'
IDERR    DC    C'ERR'
ST00     DC    C'00'
         SPACE 2
*---------------------------------------------------------------------*
*   W T O   P A R A M E T E R   L I S T   (BUILT BY HAND)             *
*---------------------------------------------------------------------*
         DS    0F
MSGWTO   DC    AL2(MSGWEND-MSGWTO)
         DC    XL2'0000'
MSGTEXT  DC    CL62' '
MSGWEND  EQU   *
TXTMAX   EQU   46
         SPACE 2
*---------------------------------------------------------------------*
*   W O R K   A R E A S                                               *
*---------------------------------------------------------------------*
         DS    0F
SAVEAREA DS    18F
SAYSAVE  DS    F
SNDSAVE  DS    F
EOTSAVE  DS    F
RCVSAVE  DS    F
RETSAVE  DS    F
DMPSAVE  DS    F
SHWSAVE  DS    F
NAPSAVE  DS    F
STPSAVE  DS    F
COMPTR   DS    F
MSGADDR  DS    F
MSGLEN   DS    F
RCTSAVE  DS    F
PRSSAVE  DS    F
PRCSAVE  DS    F
GNXSAVE  DS    F
UPDSAVE  DS    F
GTFSAVE  DS    F
FDBSAVE  DS    F
ACBSAVE  DS    F
SFBSAVE  DS    F
SKYSAVE  DS    F
SNMSAVE  DS    F
RECCOUNT DS    F                   CONTROL RECORDS READ THIS CYCLE
DONECNT  DS    F                   ... OF WHICH MARKED COMPLETE
ERRCNT   DS    F                   ... AND OF WHICH FAILED
LINECNT  DS    F                   DATA LINES IN THE CURRENT FILE
FDBKW    DS    F                   VSAM FEEDBACK, SET BY SHOWCB
FDBKC    EQU   FDBKW+3             ... THE CODE IS THE LOW BYTE
         DS    0D
DWORD    DS    D
NUMBUF   DS    CL8
TERMCH   DS    CL1                 ETX OR ETB THAT ENDED THE LAST BLOCK
         DS    0F
IOWSAVE  DS    F
WAITLST  DS    2F                  OPERATION ECB , THEN THE TIMER ECB
TIMERECB DS    F
HIBIT    DC    X'80000000'         LAST ENTRY MARKER FOR AN ECB LIST
IOTIMEL  DC    AL4(IOTIMLV)        LIMIT FOR WAITING ON THE PARTNER
IOTIMES  DC    AL4(IOTIMSV)        LIMIT FOR A BID
IOTIMEA  DS    F                   THE ONE IN FORCE FOR THIS OPERATION
SLBSAVE  DS    F
F15      DC    F'15'
ONESECX  DC    X'00000064'         100 = ONE SECOND IN 1/100 UNITS
STOPFLAG DC    C'N'
HEXOUT   DC    CL46' '
BLANKS   DC    CL46' '
HEXTAB   DC    C'0123456789ABCDEF'
LERBEYE  DC    C'*LERBEND*'        REFERENCE COPY OF THE LERB FENCE -
*                                  DELIBERATELY NOT NEXT TO THE LERB
         SPACE 2
*---------------------------------------------------------------------*
*   M E S S A G E S   -  ALL PADDED TO 62 BYTES                       *
*---------------------------------------------------------------------*
MSG010   DC    CL62'BSCFTCH 010 STARTING'
MSG012   DC    CL62'BSCFTCH 012 COMMAND INTERFACE READY - P TO STOP'
MSG014   DC    CL62'BSCFTCH 014 NO COMMAND INTERFACE - NOT A STC'
MSG020   DC    CL62'BSCFTCH 020 OPENING BSC LINE GROUP - DD BSCLINE'
MSG022   DC    CL62'BSCFTCH 022 OPEN FAILED - WILL RETRY'
MSG024   DC    CL62'BSCFTCH 024 LINE GROUP IS OPEN'
MSG030   DC    CL62'BSCFTCH 030 HEL SENT - WAITING FOR THE PARTNER'
MSG032   DC    CL62'BSCFTCH 032 UNEXPECTED REPLY - EXPECTED DAT00'
MSG034   DC    CL62'BSCFTCH 034 PARTNER ANSWERED - LINE IS GOOD'
MSG036   DC    CL62'BSCFTCH 036 LINE ERROR DURING THE HELLO EXCHANGE'
MSG050   DC    CL62'BSCFTCH 050 LINE CLOSED - WAITING 15 SECONDS'
MSG100   DC    CL62'BSCFTCH 100 OPENING THE CONTROL FILE - DD CTLFILE'
MSG102   DC    CL62'BSCFTCH 102 CONTROL FILE OPEN FAILED - ACB ERROR'
MSG104   DC    CL62'BSCFTCH 104 CONTROL FILE READ FAILED'
MSG110   DC    CL62'BSCFTCH 110 CONTROL RECORD UPDATE FAILED'
MSG112   DC    CL62'BSCFTCH 112 CONTROL RECORD MARKED COMPLETE'
MSG120   DC    CL62'BSCFTCH 120 UNEXPECTED MESSAGE ID IN THE REPLY'
MSG122   DC    CL62'BSCFTCH 122 PARTNER RETURNED AN ERROR'
MSG124   DC    CL62'BSCFTCH 124 ENDED WITHOUT AN EOF BLOCK'
MSG930   DC    CL62'BSCFTCH 930 READ TT DID NOT POST NORMAL'
MSG940   DC    CL62'BSCFTCH 940 BTAM NEVER POSTED - ABANDONING CYCLE'
MSG162   DC    CL62'BSCFTCH 162 LERB FENCE CORRUPT - OVER 64 BYTES'
MSG164   DC    CL62'BSCFTCH 164 ENLARGE LERBLK - SEE GC27-6980'
MSGKEY   DC    CL62'BSCFTCH 150 KEY='
MSGLINES DC    CL62'BSCFTCH 130 DATA LINES RECEIVED'
MSGREC   DC    CL62'BSCFTCH 140 CONTROL RECORDS READ'
MSGDONE  DC    CL62'BSCFTCH 142 RECORDS MARKED COMPLETE'
MSGERRS  DC    CL62'BSCFTCH 144 RECORDS WITH ERROR'
MSG900   DC    CL62'BSCFTCH 900 SHUTTING DOWN'
MSG910   DC    CL62'BSCFTCH 910 STOP COMMAND ACCEPTED'
MSG912   DC    CL62'BSCFTCH 912 COMMAND IGNORED - ONLY STOP IS HANDLED'
MSG920   DC    CL62'BSCFTCH 920 WRITE TI DID NOT POST NORMAL'
MSG922   DC    CL62'BSCFTCH 922 WRITE TR DID NOT POST NORMAL'
MSG924   DC    CL62'BSCFTCH 924 READ TI DID NOT POST NORMAL'
MSG926   DC    CL62'BSCFTCH 926 DECB AFTER THE READ'
MSG928   DC    CL62'BSCFTCH 928 READ RETURNED NO USABLE DATA'
MSGHEX   DC    CL62'BSCFTCH 900 HEX='
MSGRECV  DC    CL62'BSCFTCH 910 RCV='
         EJECT
*---------------------------------------------------------------------*
*   M A P P I N G   M A C R O S                                       *
*                                                                     *
*   NEITHER OF THESE GENERATES A DSECT OF ITS OWN - IEZCOM EMITS      *
*   COMLIST EQU * FOLLOWED BY BARE DS STATEMENTS , AND IEZCIB SAYS SO *
*   IN ITS OWN COMMENTS -                                             *
*                                                                     *
*     A DSECT CARD SHOULD PRECEDE MACRO CALL.  USING ON CIBNEXT       *
*     GIVES ADDRESSABILITY FOR ALL SYMBOLS.                           *
*                                                                     *
*   SO THE DSECT CARDS BELOW ARE OURS.  WITHOUT THEM THE FIELDS LAND  *
*   IN WHATEVER LOCATION COUNTER HAPPENS TO BE CURRENT , WHICH        *
*   RESOLVES BUT ADDRESSES THE WRONG STORAGE.                         *
*                                                                     *
*   LAYOUT AS GENERATED ON THIS SYSTEM -                              *
*     COMAREA  +0 COMECBPT  +4 COMCIBPT                               *
*     CIBAREA  +0 CIBNEXT   +4 CIBVERB  +5 CIBLEN                     *
*              +14 CIBDATLN +16 CIBDATA                               *
*     VERBS    CIBSTART X'04'  CIBMODFY X'44'  CIBSTOP X'40'          *
*---------------------------------------------------------------------*
COMAREA  DSECT
         IEZCOM
         SPACE 1
CIBAREA  DSECT
         IEZCIB
         END   BSCFTCH
