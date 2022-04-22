# This script is written based on Windows Powershell
# This script is developed for migrating your on-premise SQL Server database to AWS RDS
# Setup parameters
Param (
    [parameter(
        Mandatory=$true,
        HelpMessage="Please enter which environment you want to execute this script",
        Position=1)]
    [ValidateSet('dev','qc','uat','pse','prod')]
    [string]$env,
    [parameter(
        Mandatory=$false,
        HelpMessage="Please enter which action you want to do? backup or restore?",
        Position=2)]
    [ValidateSet('backup','restore')]
    [string]$action='backup'
)

# Setup all the static variables for each environment using
switch ($env)
{
    "dev" {
        $server_name = "cwddbs06dsro"
        $bucket_name = "mssql-migration-bucket-dev"
        $backup_path = "F:\Backup\AutoBackup"
        $server_instance = "mssql-db-dev.us-east-1.rds.amazonaws.com"
        $user_name = "sqladmin"
        $secret_name = "/dev/mssql_database/password"
    }
    "qc" {
        $server_name = ""
        $bucket_name = ""
        $backup_path = ""
        $server_instance = ""
        $user_name = ""
        $secret_name = ""
    }
    "uat" {
        $server_name = ""
        $bucket_name = ""
        $backup_path = ""
        $server_instance = ""
        $user_name = ""
        $secret_name = ""
    }
    "pse" {
        $server_name = ""
        $bucket_name = ""
        $backup_path = ""
        $server_instance = ""
        $user_name = ""
        $secret_name = ""
    }
    "prod" {
        $server_name = ""
        $bucket_name = ""
        $backup_path = ""
        $server_instance = ""
        $user_name = ""
        $secret_name = ""
    }
}

$restore_template = @"
exec msdb.dbo.rds_restore_database
@restore_db_name='#dbName',
@s3_arn_to_restore_from='arn:aws:s3:::#bucket-name/#dbName.bak',
@type='FULL',
@with_norecovery=1;
exec msdb.dbo.rds_finish_restore @db_name='#dbName';
"@

# Decide to run the backup scripts or restore scripts
if($action -match "backup") {
    Set-Location "F:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\Data"

    # Get all databases name and export them to *.bak files
    foreach ($database in (Get-ChildItem -Path "SQLSERVER:\SQL\$server_name\default\databases"))
    {
        $db_name = $database.Name
        Backup-SqlDatabase -ServerInstance $server_name -Database $dbName -BackupFile "$backup_path\$db_name.bak" -Credential $user_name -CompressionOption On
        # Upload the *.bak files to s3 bukcet then remove the temp files
        aws s3 cp "$backup_path\$db_name.bak" "s3://$bucket_name/$db_name.bak"
        Write-Host "File " $db_name.bak "has been uploaded to s3 successfully!"
        Remove-Item "$backup_path\$db_name.bak"
    }
} else {
    # Define temp file
    $temp_file = "temp.sql"
    # Get database password from aws secrets manager
    $secret = aws secretsmanager get-secret-value --secret-id $secret_name | ConvertFrom-Json
    $db_password = $secret.SecretString | ConvertFrom-Json
    $db_password = $db_password.password

    # Replace the necessary variables in the template content and output the new content into a temp file
    foreach ($database in (aws s3 ls s3://$bucket_name)) {
        # Get the bak file names
        $file_name = $database.Trim().Split(" ")
        $file_name = $file_name[$file_name.length - 1]
        $db_name = $file_name.Trim().Split(".")[0]

        # Replace the template content
        $sql = $restore_template.Replace('#dbName',$db_name).Replace("#bucket-name", $bucket_name) | Out-File $temp_file

        Invoke-Sqlcmd -ServerInstance $server_instance -InputFile $sql -Username $user_name -Password $db_password
    }

    Remove-Item $temp_file
}







