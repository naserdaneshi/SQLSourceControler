USE Master
GO
/*
	Author: Naser Daneshi 2018-10-06
	This is a TRIGGER fires on Instance Level of SQL server can control and create history of any database's level event 
	include creation , deletion , modification and so on.
	To do that this tigger fires when a command send to the SQL engine and catches the content of script 
	then compare the new script with the latest script on the audition database if allows the new record will be inserted 
	else it shows an suitable error to the user   
*/
CREATE  TRIGGER [DDLTriggerRoutineLevel] ON ALL SERVER  FOR 
	CREATE_PROCEDURE,	ALTER_PROCEDURE, DROP_PROCEDURE,
	CREATE_FUNCTION,	ALTER_FUNCTION, DROP_FUNCTION,
	CREATE_TRIGGER,		ALTER_TRIGGER, DROP_TRIGGER,
	CREATE_VIEW,		ALTER_VIEW, DROP_VIEW

AS
BEGIN

    SET NOCOUNT ON;
	DECLARE @IsNoLimit bit=0;
	DECLARE @TEMPOLD TABLE( ItemOld nvarchar(4000) )
	DECLARE @TEMPNEW TABLE( ItemNew nvarchar(4000) )

	DECLARE 
		@SPID			nvarchar(10),
		@EventType		nvarchar(64),
		@EventDDL		nvarchar(MAX),
		@EventXML		XML,
		@DatabaseName	nvarchar(255),
		@SchemaName		nvarchar(255),
		@ObjectName		nvarchar(255),
		@HostName		nvarchar(255),
		@ProgramName	nvarchar(255),
		@LoginName		nvarchar(255),
		@RoutineName	nvarchar(100)
	-- Catch the new command called EVENT . the content is in EventXML , It must be extracted
	DECLARE @EventData XML = EVENTDATA();
	SELECT
		@SPID			= @EventData.value('(/EVENT_INSTANCE/SPID)[1]','NVARCHAR(10)'), 
		@EventType		= @EventData.value('(/EVENT_INSTANCE/EventType)[1]','NVARCHAR(100)'), 
		@EventDDL		= @EventData.value('(/EVENT_INSTANCE/TSQLCommand)[1]','NVARCHAR(MAX)'),
		@EventXML		= @EventData,
		@DatabaseName	= @EventData.value('(/EVENT_INSTANCE/DatabaseName)[1]','NVARCHAR(255)'),
		@SchemaName		= @EventData.value('(/EVENT_INSTANCE/SchemaName)[1]','NVARCHAR(255)'), 
		@ObjectName		= @EventData.value('(/EVENT_INSTANCE/ObjectName)[1]','NVARCHAR(255)'),
		@HostName		= HOST_NAME(),
		@ProgramName	= PROGRAM_NAME(),
		@LoginName		= SUSER_SNAME()
	
	-- Will not working on the below databases
	IF LOWER(@DatabaseName) not in( 'Database1' , 'Database2')  RETURN	
	-- Also for this function
	IF @ObjectName = 'DDLTriggerRoutineLevel' RETURN
	-- The admin fixed role users are exception. They can do whatever they want .
	IF @LoginName in('bp_admin1','bp_admin2','dba2') SET @IsNoLimit =1;  

	DECLARE @ErrorMsg NVARCHAR(MAX)=''

	DECLARE @Author nvarchar(255)=NULL ,@IsAuthorLock bit , @AccessLevelID tinyint, @MyAccessLevelID  tinyint

	--print @IsNoLimit
	-- Maybe a use wants to disable this trigger for sabotage porpuse
	IF @EventType ='ALTER_TRIGGER' and ( @LoginName not in ('bp_admin1','dba2','bp_admin2') /*or @IsNoLimit =0*/)
	BEGIN
		RAISERROR('Access denied...', 16,1)
		ROLLBACK;
		RETURN
	END

	SELECT @MyAccessLevelID =_AccessLevelID FROM wiki.Employers Where LoginName =@LoginName
	-- Has this user permission to modify the routine?
	IF ( @MyAccessLevelID IS NULL AND  @IsNoLimit=0 )
	BEGIN
		SET	@ErrorMsg =  'No permission granted to this user =>'+@LoginName;
		RAISERROR(@ErrorMsg, 16,1)
		ROLLBACK;
		RETURN
	END
	
	;WITH CTE AS
	(
		SELECT 'F' as Type, ID,SchemaName,ObjectName,Author,IsAuthorLock,_AccessLevelID FROM wiki.Functions
		UNION 
		SELECT 'P' as Type, ID,SchemaName,ObjectName,Author,IsAuthorLock,_AccessLevelID FROM wiki.Procedures
	)
	SELECT 
		@Author = Author, @IsAuthorLock = IsAuthorLock, @AccessLevelID = _AccessLevelID  
	FROM CTE 
	WHERE SchemaName =  @SchemaName and ObjectName = @ObjectName;
	-- Every routine has an owner and the user having lower permission can not access to the routine.
	IF @Author IS NOT NULL --  @Author IS NULL  means it is a new routine
	BEGIN
		IF (@IsAuthorLock=1) and @Author <> @LoginName  and  @IsNoLimit =0
		BEGIN
			SET	@ErrorMsg = 'You dont have permission to modify th routine. The owner of this is '+@Author
			RAISERROR(@ErrorMsg, 16,1)
			ROLLBACK;
			RETURN
		END
		ELSE
		IF @IsAuthorLock=0 AND @MyAccessLevelID> @AccessLevelID 
		BEGIN
			RAISERROR( 'You dont have permission to modify the routine. Your access level is only read', 16,1)
			ROLLBACK;
			RETURN
		END
	END
	
	SET @RoutineName = @SchemaName+'.'+@ObjectName 

	DECLARE	
		@HeaderComments		nvarchar(max)='',
		@BodyOld			nvarchar(max)='',
		@BodyNew			nvarchar(max)='',
		@NewHeaderSQLData	nvarchar(max)='', 
		@OldHeaderSQLData	nvarchar(max)='', 
		@OldText			nvarchar(max)='', 
		@RemainText			nvarchar(max)='',
		@Today				nvarchar( 10)='';
	DECLARE
		@OldDatabaseName	nvarchar(255)='',
		@OldLoginName		nvarchar(255)='',
		@OldSPID			nvarchar( 10)='',
		@OldObjectName		nvarchar(255)='',
		@OldEventDate		Datetime;

	DECLARE	@ErrCode int=0; 
			/* 
				 1: Body not Changed				 
				 0: Acceptable					
				-1: There is no comment 
				-2: The previous comment is deleted 
				-3: New comment has no enough characters
				-4: There is no Date tracker in comment
				-5: Date tracker is not valid
			*/
	BEGIN TRY	
		-- Extract the comment written for this routine.
		-- Note: users must write some comment for the reason of modification and it must be written before of definition(CREATE or ALTER Statement).		
		SELECT @HeaderComments = Audition.tools.getCommentOnScript(@EventDDL)

		SELECT @Today=PersianDate FROM Audition.tools.PersianDates where EnglishDate =CAST( GETDATE() as DATE) 
		-- Check DROP command is forbidden for this user
		IF @IsNoLimit =0 and  @EventType in('DROP_PROCEDURE','DROP_FUNCTION','DROP_TRIGGER','DROP_VIEW') 
		BEGIN
			IF @IsAuthorLock=1 and @Author <> @LoginName 
			RAISERROR(N'The DROP command is not permitted, DROP command removes all permissions that set on the routine',16,1)
		END	
		
		-- Check ALTER command for view, function, stored procedures and triggers 
		 
		IF @IsNoLimit =0 AND @EventType IN('ALTER_PROCEDURE','ALTER_FUNCTION','ALTER_TRIGGER','ALTER_VIEW') 
		BEGIN
			-- Find the latest script for this object. It must be compared with the new script
			SELECT TOP 1 
				@OldText = EventDDL, 
				@OldDatabaseName = DatabaseName , 
				@OldLoginName = LoginName , 
				@OldObjectName = ObjectName , 
				@OldSPID = SPID , 
				@OldEventDate = EventDate
			FROM Audition.dbo.DDLEventsRoutine 
			WHERE @DatabaseName= DatabaseName and SchemaName = @SchemaName and ObjectName=@ObjectName 
			ORDER BY EventDate DESC
														
			IF ISNULL(@OldText,'') <> ''
			BEGIN
				SELECT 
						-- To compare the content of scripts It should extract the comment and body of new script 
						-- and remove any line feed and space characters to compress the text 
						-- then compare new to old 
						@OldHeaderSQLData= Audition.tools.trimSpaceLineFeeds(Audition.tools.getCommentOnScript(@OldText) ), 
						@NewHeaderSQLData= Audition.tools.trimSpaceLineFeeds(Audition.tools.getCommentOnScript(@EventDDL)),
						@BodyOld= Audition.tools.trimSpaceLineFeeds(Audition.tools.getBodyOnScript(@OldText) ),
						@BodyNew=Audition.tools.trimSpaceLineFeeds(Audition.tools.getBodyOnScript(@EventDDL))
				IF 
						@BodyNew <> @BodyOld AND 
						@NewHeaderSQLData=@OldHeaderSQLData AND
						@DatabaseName= @OldDatabaseName AND 
						@ObjectName = @OldObjectName AND 
						@LoginName = @OldLoginName AND 
						DATEDIFF(MINUTE, @OldEventDate,GETDATE())<=120
					SET @ErrCode =2
				ELSE				
				IF (@BodyNew= @BodyOld) AND (@OldHeaderSQLData=@NewHeaderSQLData)
					SET @ErrCode =1
				ELSE
				IF @NewHeaderSQLData= ''
					SET @ErrCode =-1
				ELSE
				BEGIN
					-- Extracts the Script by line then compares them 
					INSERT INTO @TEMPOLD( ItemOld )
						SELECT LTRIM(RTRIM( REPLACE( Item, CHAR(9), ''))) ItemOld FROM Audition.tools.stringToTable_Not_NULL(@OldHeaderSQLData,CHAR(10)) WHERE NULLIF( LTRIM(RTRIM( REPLACE( Item, CHAR(9), ''))), CHAR(13) ) IS NOT NULL
					INSERT INTO @TEMPNEW( ItemNew )
						SELECT LTRIM(RTRIM( REPLACE( Item, CHAR(9), ''))) ItemNew FROM Audition.tools.stringToTable_Not_NULL(@NewHeaderSQLData,CHAR(10)) WHERE NULLIF( LTRIM(RTRIM( REPLACE( Item, CHAR(9), ''))), CHAR(13) ) IS NOT NULL

				  	IF EXISTS(SELECT * FROM @TEMPOLD O LEFT JOIN  @TEMPNEW N ON O.ItemOld = N.ItemNew WHERE ItemNew IS NULL) 
						SET @ErrCode =-2  
					ELSE
					IF NOT EXISTS(SELECT * FROM @TEMPNEW N LEFT JOIN  @TEMPOLD O ON O.ItemOld = N.ItemNew WHERE ItemOld IS NULL) 
					BEGIN
						IF @BodyNew <> @BodyOld
							SET @ErrCode =-1
					END
					ELSE
					BEGIN
						SELECT @RemainText=@RemainText+''+ItemNew FROM @TEMPNEW N LEFT JOIN  @TEMPOLD O ON O.ItemOld = N.ItemNew Where ItemOld IS NULL
						SET @RemainText= Audition.tools.RemoveSpaceLineFeeds(@RemainText)
				
						--print @RemainText
						
						-- Check the persian Date REGEX
						IF LEN( Audition.tools.RemoveNonContextChars(@RemainText)  ) <20
							SET @ErrCode =-3
						ELSE
						IF PATINDEX('%13[0-9][0-9]/[0-9][0-9]/[0-9][0-9]%', @RemainText) =0 
							SET  @ErrCode =-4
						ELSE
						BEGIN

							DECLARE @P INT= PATINDEX('%13[0-9][0-9]/[0-9][0-9]/[0-9][0-9]%', @RemainText);
							SET @RemainText = SUBSTRING(@RemainText, @P,10)
							IF NOT EXISTS(SELECT * FROM Audition.tools.PersianDates WHERE EnglishDate =CAST( GETDATE() AS DATE) AND PersianDate = @RemainText ) SET @ErrCode = -4
						END
					END
				END	
			END

		END	

		IF @ErrCode<0 
		BEGIN
			DECLARE @MSG NVARCHAR(100) ='The entered datetime is not valid, please enter today ('+ @Today+')';
			IF @ErrCode =-1 RAISERROR(N'The comment of modified section is too short and today DATE is not valid',16,1)
			ELSE
			IF @ErrCode =-2 RAISERROR(N'Your codes is older than the original so it can not be useable',16,1)
			ELSE
			IF @ErrCode =-3 RAISERROR(N'The comment of modified section is too short',16,1)
			ELSE
			IF @ErrCode =-4 RAISERROR(@MSG,16,1)	
		END 
		-- Every thin is good it inserts into audition database
		IF @ErrCode IN( 0, 2 ) 
			INSERT audition.dbo.DDLEventsRoutine(SPID, EventType,	EventDDL, EventXML, DatabaseName, SchemaName, ObjectName, HostName,	ProgramName, LoginName,  HeaderComments )
			VALUES(@SPID,@EventType, @EventDDL, @EventXML, @DatabaseName, @SchemaName, @ObjectName, @HostName, @ProgramName,	@LoginName,   @HeaderComments )
	END TRY
	BEGIN CATCH
		SET	@ErrorMsg = ERROR_MESSAGE()
		RAISERROR( @ErrorMsg, 16,1)
		ROLLBACK;

	END CATCH
	
END


GO
/*
	Author: Naser Daneshi 2018-10-08
	It removes any comments written before definition of routine
*/
CREATE	FUNCTION [tools].[getBodyOnScript](@TextValue as nvarchar(max)) Returns nvarchar(max) AS
BEGIN
	DECLARE @S nvarchar(max)='', @BlockComment int=0, @LineComment bit=0;
	DECLARE @I int =1, @Pos int =0, @Length int= Len(@TextValue);
	WHILE @I <= @Length
	BEGIN
		IF Substring(@TextValue, @I-2, 2 ) = '/*'		
			SET @BlockComment +=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '*/'	
			SET @BlockComment -=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '--'	
			SET @LineComment =1
		ELSE 
		IF (Substring(@TextValue, @I-1, 1 ) = CHAR(10)) OR (Substring(@TextValue, @I-1, 1 ) =CHAR(13)) 
			SET @LineComment =0  
		
		SET @S = Substring(@TextValue, @I-6, 6 )
		IF (@s = 'create') and (@BlockComment =0 and @LineComment= 0)
		BEGIN
			SET @Pos = @I-6
			BREAK
		END
		
		SET @S = Substring(@TextValue, @I-5, 5 )
		IF (@s = 'alter') and (@BlockComment =0 and @LineComment= 0)
		BEGIN
			SET @Pos = @I-5
			BREAK
		END
		
		SET @i += 1
 
	END;
	
	IF @BlockComment <>0	RETURN	'Error in comments( Pair matching error )'
	
	IF @Pos = 0				RETURN @TextValue
	
	RETURN Substring (@TextValue, @Pos, Len(@TextValue)-@Pos+1 )
END
GO

/****** Object:  UserDefinedFunction [tools].[getCommentOnScript]    Script Date: 3/30/2018 05:32:18 ب.ظ ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO
/*
	Author: Naser Daneshi 2018-10-08
	It extracts any comments written before definition of routine
*/
CREATE	FUNCTION [tools].[getCommentOnScript](@TextValue as nvarchar(max)) Returns nvarchar(max) AS
BEGIN
	DECLARE @S nvarchar(max)='', @BlockComment int=0, @LineComment bit=0;
	DECLARE @I int =1, @Pos int =0, @Length int= Len(@TextValue);
	WHILE @I <= @Length
	BEGIN
		IF Substring(@TextValue, @I-2, 2 ) = '/*'		
			SET @BlockComment +=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '*/'	
			SET @BlockComment -=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '--'	
			SET @LineComment =1
		ELSE 
		IF (Substring(@TextValue, @I-1, 1 ) = CHAR(10)) OR (Substring(@TextValue, @I-1, 1 ) =CHAR(13)) 
			SET @LineComment =0  
		
		SET @S = Substring(@TextValue, @I-6, 6 )
		IF (@s = 'create') and (@BlockComment =0 and @LineComment= 0)
		BEGIN
			SET @Pos = @I-6
			BREAK
		END
		
		SET @S = Substring(@TextValue, @I-5, 5 )
		IF (@s = 'alter') and (@BlockComment =0 and @LineComment= 0)
		BEGIN
			SET @Pos = @I-5
			BREAK
		END
		
		SET @i += 1
 
	END;
 
	IF @BlockComment <>0	RETURN	'Error in comments( Pair matching error )'
	
	IF @Pos = 0				RETURN ''
	
	RETURN	Substring (@TextValue, 1,@Pos-1)
END
 
GO

/****** Object:  UserDefinedFunction [tools].[getCommentOnScriptAlter]    Script Date: 3/30/2018 05:32:18 ب.ظ ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/*
	Author: Naser Daneshi 2018-10-08
	It extracts any comments written before ALTER reserved word will be appeared
*/
CREATE	FUNCTION [tools].[getCommentOnScriptAlter](@TextValue as nvarchar(max)) Returns nvarchar(max) AS
BEGIN
	DECLARE @S nvarchar(max)='', @BlockComment int=0, @LineComment bit=0;
	DECLARE @I int =1, @Pos int =0, @Length int= Len(@TextValue);
	WHILE @I <= @Length
	BEGIN
		IF Substring(@TextValue, @I-2, 2 ) = '/*'		
			SET @BlockComment +=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '*/'	
			SET @BlockComment -=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '--'	
			SET @LineComment =1
		ELSE 
		IF (Substring(@TextValue, @I-1, 1 ) = CHAR(10)) OR (Substring(@TextValue, @I-1, 1 ) =CHAR(13)) 
			SET @LineComment =0  
 
		SET @S = Substring(@TextValue, @I-5, 5 )
		IF (@s = 'alter') and (@BlockComment =0 and @LineComment= 0)
		BEGIN
			SET @Pos = @I-5
			BREAK
		END
		
		SET @i += 1
 
	END;
 
	IF @BlockComment <>0	RETURN	'Error in comments( Pair matching error )'
 
	IF @Pos = 0			RETURN '';
 
	RETURN Substring (@TextValue, 1,@Pos-1)
END
 
GO

/****** Object:  UserDefinedFunction [tools].[getCommentOnScriptCreate]    Script Date: 3/30/2018 05:32:18 ب.ظ ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO
/*
	Author: Naser Daneshi 2018-10-08
	It extracts any comments written before CREATE reserved word will be appeared
*/
CREATE	FUNCTION [tools].[getCommentOnScriptCreate](@TextValue as nvarchar(max)) Returns nvarchar(max) AS
BEGIN
	DECLARE @S nvarchar(max)='', @BlockComment int=0, @LineComment bit=0;
	DECLARE @I int =1, @Pos int =0, @Length int= Len(@TextValue);
	WHILE @I <= @Length
	BEGIN
		IF Substring(@TextValue, @I-2, 2 ) = '/*'		
			SET @BlockComment +=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '*/'	
			SET @BlockComment -=1
		ELSE 
		IF Substring(@TextValue, @I-2, 2 ) = '--'	
			SET @LineComment =1
		ELSE 
		IF (Substring(@TextValue, @I-1, 1 ) = CHAR(10)) OR (Substring(@TextValue, @I-1, 1 ) =CHAR(13)) 
			SET @LineComment =0  
		
		SET @S = Substring(@TextValue, @I-6, 6 )
		IF (@s = 'create') and (@BlockComment =0 and @LineComment= 0)
		BEGIN
			SET @Pos = @I-6
			BREAK
		END
 
		SET @i += 1
 
	END;
 
	IF @BlockComment <>0	RETURN	'Error in comments( Pair matching error )'
 
	IF @Pos = 0			RETURN '';
 
	RETURN Substring (@TextValue, 1,@Pos-1)
END
GO

/****** Object:  UserDefinedFunction [tools].[RemoveNonContextChars]    Script Date: 3/30/2018 05:32:18 ب.ظ ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION [tools].[RemoveNonContextChars]( @S NVARCHAR(MAX) ) RETURNS NVARCHAR(MAX) AS
BEGIN
	RETURN 
	REPLACE(
	REPLACE(
	REPLACE(
	REPLACE(
	REPLACE(
	REPLACE(
	REPLACE(
	REPLACE(
	REPLACE(
	REPLACE(@S,'*','')
			,'/','')
			,'-','')
			,' ','')
			,';','')
			,':','')
			,',','')
			,'.','')
			,'=','')
			,'+','')

END

GO

/****** Object:  UserDefinedFunction [tools].[RemoveSpaceLineFeeds]    Script Date: 3/30/2018 05:32:18 ب.ظ ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION [tools].[RemoveSpaceLineFeeds]( @S NVARCHAR(MAX) ) RETURNS NVARCHAR(MAX) AS
BEGIN
	RETURN 
	REPLACE(
		REPLACE(
			REPLACE(
				REPLACE(@S,CHAR(10),'')
				,CHAR(13),'')
			,CHAR(9),'')
		,CHAR(32),'')

END

GO

/****** Object:  UserDefinedFunction [tools].[trimSpaceLineFeeds]    Script Date: 3/30/2018 05:32:18 ب.ظ ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION [tools].[trimSpaceLineFeeds]( @S NVARCHAR(MAX) ) RETURNS NVARCHAR(MAX) AS
BEGIN
	DECLARE @Temp nvarchar(max) =LTRIM(RTRIM(@S));
	
	WHILE 1=1 
	BEGIN
		IF LEN(@TEMP) =0 BREAK
		IF ASCII(RIGHT(@TEMP,1)) IN (9,10,13)	
			SET @TEMP = LEFT(@TEMP, Len(@TEMP)-1)
		ELSE
		IF ASCII(RIGHT(@TEMP,1)) IN (32)	
			SET @TEMP = RTRIM(@TEMP)
		ELSE
			BREAK
	END;

	WHILE 1=1 
	BEGIN
		IF LEN(@TEMP) =0 BREAK
		IF ASCII(LEFT(@TEMP,1)) IN (9,10,13)	
			SET @TEMP = RIGHT(@TEMP, Len(@TEMP)-1)
		ELSE
		IF ASCII(LEFT(@TEMP,1)) IN (32)	
			SET @TEMP = LTRIM(@TEMP)
		ELSE
			BREAK
	END;

	RETURN @TEMP
END

GO

