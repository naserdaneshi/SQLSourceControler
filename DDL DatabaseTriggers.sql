SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- DDL Trigger
-- We need to avoid any unwanted modifications on database routines.
-- only users with administrator fix role can modify.
-- So due to check history of any action on databases it's important to log any commands( Events ).
CREATE trigger [DDLTriggerAudition]
	on database
    for create_procedure, alter_procedure, drop_procedure, create_table, alter_table, drop_table, 
	alter_schema, RENAME, create_function, alter_function, drop_function, create_index ,alter_index, 
	drop_index,create_view ,alter_view ,drop_view
	
as 

begin

    set nocount on;

	declare @EventData xml = eventdata();

	declare @ip VARCHAR(32) = (select Top 1  client_net_address
								from sys.dm_exec_connections
								where session_id = @@SPID);
	-- EventXML includes content of command						
	insert audition.dbo.DDLEvents
	(
		EventType,
		EventDDL,
		EventXML,
		DatabaseName,
		SchemaName,
		ObjectName,
		HostName,
		IPAddress,
		ProgramName,
		LoginName
	)
	select
		@EventData.value('(/EVENT_INSTANCE/EventType)[1]',   'NVARCHAR(100)'), 
		@EventData.value('(/EVENT_INSTANCE/TSQLCommand)[1]', 'NVARCHAR(MAX)'),
		@EventData,
		db_name(),
		@EventData.value('(/EVENT_INSTANCE/SchemaName)[1]',  'NVARCHAR(255)'), 
		@EventData.value('(/EVENT_INSTANCE/ObjectName)[1]',  'NVARCHAR(255)'),
		host_name(),
		@ip,
		PROGRAM_NAME(),
		suser_sname();
	revert
end




GO

DISABLE TRIGGER [DDLTriggerAudition] ON DATABASE
GO

/****** Object:  DdlTrigger [NO_DROP_Function]    Script Date: 7/11/2018 9:34:08 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE TRIGGER [NO_DROP_Function] ON DATABASE FOR DROP_Function
AS
declare @user nvarchar(100) 
set @user = (select system_user)
if @user not in ('bp_admin1','bp_admin2','dba2')
begin
	PRINT 'Dropping Function are not allowed'
	ROLLBACK
end



GO

DISABLE TRIGGER [NO_DROP_Function] ON DATABASE
GO

/****** Object:  DdlTrigger [NO_Drop_Procedure]    Script Date: 7/11/2018 9:34:08 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



CREATE TRIGGER [NO_Drop_Procedure] ON DATABASE FOR DROP_Procedure
AS
declare @user nvarchar(100) 
set @user = (select system_user)
if @user not in ('bp_admin1','bp_admin2','dba2')
begin 
	PRINT 'Dropping Procedure are not allowed'
	ROLLBACK
end

GO

DISABLE TRIGGER [NO_Drop_Procedure] ON DATABASE
GO

/****** Object:  DdlTrigger [NO_DROP_Table]    Script Date: 7/11/2018 9:34:08 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE TRIGGER [NO_DROP_Table] ON DATABASE
FOR DROP_TABLE, DROP_INDEX, CREATE_FULLTEXT_INDEX, ALTER_FULLTEXT_INDEX, DROP_FULLTEXT_INDEX, CREATE_SPATIAL_INDEX,
CREATE_XML_INDEX, CREATE_TABLE, ALTER_TABLE, RENAME
AS
DECLARE @user nvarchar(100) 
SET @user = (SELECT SYSTEM_USER)
if @user not in ('bp_admin1','bp_admin2','dba2')
BEGIN 
	PRINT 'Dropping Table are not allowed'
	ROLLBACK
END
GO

DISABLE TRIGGER [NO_DROP_Table] ON DATABASE
GO

/****** Object:  DdlTrigger [NO_DROP_TRIGGER]    Script Date: 7/11/2018 9:34:08 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE TRIGGER [NO_DROP_TRIGGER] ON DATABASE FOR DROP_TRIGGER
AS
declare @user nvarchar(100) 
set @user = (select system_user)
if @user not in ('bp_admin1','bp_admin2','dba2')
begin
	PRINT 'Dropping TRIGGER are not allowed'
	ROLLBACK
end


GO

DISABLE TRIGGER [NO_DROP_TRIGGER] ON DATABASE
GO

/****** Object:  DdlTrigger [NO_DROP_View]    Script Date: 7/11/2018 9:34:08 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



CREATE TRIGGER [NO_DROP_View] ON DATABASE FOR DROP_VIEW
AS
DECLARE @user NVARCHAR(100) 
SET @user = (SELECT SYSTEM_USER)
if @user not in ('bp_admin1','bp_admin2','dba2')
BEGIN
	PRINT 'Dropping View are not allowed'
	ROLLBACK
END


GO

DISABLE TRIGGER [NO_DROP_View] ON DATABASE
GO

ENABLE TRIGGER [DDLTriggerAudition] ON DATABASE
GO

ENABLE TRIGGER [NO_DROP_Function] ON DATABASE
GO

ENABLE TRIGGER [NO_Drop_Procedure] ON DATABASE
GO

ENABLE TRIGGER [NO_DROP_Table] ON DATABASE
GO

ENABLE TRIGGER [NO_DROP_TRIGGER] ON DATABASE
GO

ENABLE TRIGGER [NO_DROP_View] ON DATABASE
GO


