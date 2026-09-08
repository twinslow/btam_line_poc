# New BSC MVS based started task process and client

This new application is comprised of the following components.

* VSAM KSDS control file.
* A MVS started task which opens and communicates on a BSC line, using BTAM.
* A python client program which to responds to requests from the MVS started task, connects to Hercules simulated BSC line using a TCP connection.

The application will use the VSASM KSDS control file to specify none, one or more files to be retrieved from the remote partner. The file data will be returned to the MVS started task and will then be output via dynamically allocated SYSOUT dataset to JES2 for printing.

After printing the VSAM control record will be updated to indicate that the file has been retrieved and printed. 

## VSAM KSDS control file

The KSDS will be defined with a key length of 30 bytes and a record length of 60 bytes (including the key).

The key is a character string of 30 EBCDIC alpha-numeric characters that makes up an ID value.
The data portion of the record has the following layout --

* 1 byte status field. C'I' for in-progress, C'C' for completed, C'D' for (logically) deleted.
* 29 bytes reserved for future use.

## MVS Started Task

This will be somewhat like the BSCPOCB.asm program.

It will run as a started task and should use the MVS command interface to handle a MVS STOP command. 

### Overview

* Utilize the MVS command interface to shutdown the STC when a MVS STOP command is issued.
* Open the BSC line and send a "hello" message to the remote partner process.
* If the partner responds correctly then a "process-run" will be performed (see below).
* If the partner does not respond then the started task will close the line and wait for 60 seconds before retrying.
* Close the BSC line 
* Sleep for 60 seconds and then restart with opening the line as before.

### Process loop

1. Open the VSAM KSDS.
2. Read each record in the VSAM KSDS.
3. If the status field is C'I' then process the request.
    3a. Extract the key from the record.
    3b. Open the temporary DSORG=PS dataset for output.
    3c. Send the FETCH command to the remote process. 
    3d. Receive the responses from the remote partner, until end-of-file response or error response is received.
    3e. Write the received lines data to the temporary dataset.
    3f. If end-of-file was received then close/open-read the temporary dataset and copy the data to SYSOUT JES2 for printing.
    3g. If successfully sent to JES2 SYSOUT, update the VSAM control record to complete C'C'.
4. Fetch next record from VSAM KSDS control file if any.
5. If end of VSAM KSDS then this process-loop is complete.

### Printing to JES2 

* The MVS started task should dynamically (DYNALLOC) allocate a SYSOUT dataset, with a class of 'A'.
* When the print data has been added to the SYSOUT dataset, it should be closed and freed (DYNALLOC). 

### BSC line protocol

The BSC line is defined as non-switched point to point. 

A transmission will be made up of --
* ENQ to bid for the line
* One or more text blocks
* EOT to indicate end of transmission.

#### Text blocks

Each text block will consist of a message id of 3 EBCDIC characters, 2 EBCDIC digits for a status code and 0 to 133 characters of EBCDIC character data. The text block will be prefixed with a BSC STX character and will be terminated
with a BSC ETB or ETX character.

The message IDs are 

C'HEL' (command sent from MVS started task to fetch file data)
C'GET' (command sent from MVS started task to partner program)
C'ERR' (response from partner, indicating the command failed)
C'DAT' (response from partner, indicating a line of data in response to C'GET')
C'EOF' (response from partner, indicating the file data C'GET' is complete).

The status codes (2 digits) are 

C'00' All is good -- no error.
C'04' File specified does not exist.
C'08' An invalid command was received. More info is in data area.
C'16' Other unspecified error ... more info may be in data area.

## Partner program that runs on Linux/Unix host

The partner program will be written in python and will establish a TCP connection to the Hercules commadpt.c interface.

### Command line arguments

The partner program should accept the following command line arguments --

--host : The host name or IP address to connect to.
--port : The TCP port number to connect to.
--fdir : The file directory in which to look for files, that the MVS started task will request with C'GET' commands.

### Processing commands from MVS

The partner program needs to respond to two commands that may be sent from MVS.

#### 1. Hello C'HEL' command

1. The response will be C'DAT00Hello' as a ENQ STX text ETX EOT transmission.
2. Output a message to STDERR indicating Hello was received from MVS.

#### 2. Get C'GET' command

The partner program will -- 

1. Extract the file name from the data area of the command text block.
2. Open the specified file under the directory specified by '--fdir' command line argument.
3. Output a message to STDERR indicating the file name received and open status.
4. If the file was not found, or other open error, return a C'ERR' response to the MVS started task --
   C'ERR04file xxxx.yyyy not found'.
5. If the file was opened, read each line of text and send that line of text to the MVS started task. 
6. After reaching the end of the file, send a C'EOF00' text block to MVS.
7. Output a message to STDERR indicating the the file GET completed successfully.

