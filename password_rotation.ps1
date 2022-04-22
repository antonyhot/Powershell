# This scripts is written based on Windows Powershell and this script will be nested into AWS System Manager Documents to run
# A KMS key should be created with proper roles and this id will be one of the parameter
# Receive the KMS Key id as the parameter since EC2Rescure need it to change the Administrators' password.
# A second OPTIONAL parameter that will receive a special user name should be defined.
# If the parameter is the user Administrator, only change the password for the Administrator.
# If the parameter is a local user, only change the password for this local user.
# Retrieve all users' names and email addresses mapping from the Parameter Store, this is something like a Whitelist to identify which user's password should be rotated.
# Generate a new password and change the Administrators' password first by using EC2Rescure and send the new password to its email address.
# User Powershell command to get all windows local user and loop it, if the user is in the "Whitelist", then generate a new password and change it by using Set-LocalUser command, then send the new password to the related email address.
# If any error occurred or all users' password is done, send a summary email to our support email address , and in the email body, we need to specify which user's password has been changed successfully or failed.
# For the failed message, we need to consider combining all the messages into one email. For instance, we have 5 users' passwords that need to change, the number 1 user is successfully changed, 2 failed, 3 succeeded, 4 failed, and 5 failed. So two points here: One is we should not block other users' password rotation if one failed. Two is we should not send the error email to the individual user three times, we need to send only one email with all succeeded and failed information.
# The default execute path is C:\Windows\System32 for AWS Automation
# Setup parameters
Param (
    [parameter(
            Mandatory=$false,
            HelpMessage="Please enter user name",
            Position=1)]
    [string]$username
)

# Install AWS Cli with quiet model
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi /quiet
# Setup ENV path for aws cli
$Env:PATH += ";C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe"

# Create aws ses email template, this email template will be used to send password to each individuals
$email_template = @"
{
  "Template": {
    "TemplateName": "PasswordRotationTemplate",
    "SubjectPart": "[##usage]!! Window Server User's Password Changed!",
    "HtmlPart": "<body style=font-family:Calibri;>Dear ##name!!,<br><br>Please kindly be informed that your password for ##usage!! Windows Server ##instance_id!! has been changed to ##password!!<br><br>Please note that the password will be updated every 60 days.<br><br>Thanks for your kind attention.<br><br>Masterfile Team!<br><br>"
  }
}
"@
# Since we need to copy this shell script into AWS System Manager Documents, and {{}} are the default symbol for a variable so we need to define
# This is very interesting that the -Encoding default is utf -8 without BOM, but if remove this parameter, it is UTF-16
$email_template = $email_template.replace('##', '{{').replace('!!', '}}') | Out-File template.json -Encoding default
aws ses create-template --cli-input-json file://template.json

# Create another template to summerize status
$email_template = @"
{
  "Template": {
    "TemplateName": "PasswordRotationStatusTemplate",
    "SubjectPart": "[##usage!!] Window Server Password Update Status Summary!",
    "HtmlPart": "<body style=font-family:Calibri;>Dear,<br><br>The password rotation document has been executed and you can check the status for each user as below - <br><br>##content!!<br><br>Please note that the document will be executed in the next 60 days.<br><br>Thanks for your kind attention.<br><br>Masterfile Team!<br><br>"
  }
}
"@
$email_template = $email_template.replace('##', '{{').replace('!!', '}}') | Out-File template.json -Encoding default
aws ses create-template --cli-input-json file://template.json

# Define an function for sending emails
function send_template_email($name, $password, $address, $content, $template) {
    # Since instance id and a tag usage will be needed in email templated, so retrieve these values from EC2 instance metadata
    $instance_id = curl http://169.254.169.254/latest/meta-data/instance-id | Select Content
    $instance_id = $instance_id.Content
    $usage = curl http://169.254.169.254/latest/meta-data/tags/instance/Usage | Select Content
    $usage = $usage.Content

    # Convert all email address to lower case since the SES is still in sandbox so the email validation address are all lowercases.
    $address = $address.ToLower()

    # Based on variable to determine which template will be used and set all necessary values.
    if ($template -eq "PasswordRotationTemplate") {
        $json = @"
{
  "Source":"Test <test@test.com>",
  "Template": "PasswordRotationTemplate",
  "Destination": {
    "ToAddresses": [ "$address"]
  },
  "TemplateData": "{ \"usage\":\"$usage\", \"name\": \"$name\", \"instance_id\": \"$instance_id\", \"password\": \"$password\" }"
}
"@
    } else {
        $json = @"
{
  "Source":"Test <test@test.com>",
  "Template": "PasswordRotationStatusTemplate",
  "Destination": {
    "ToAddresses": [ "test@test.com"]
  },
  "TemplateData": "{ \"usage\":\"$usage\", \"content\":\"$content\" }"
}
"@
    }

    # Send emails.
    $json = $json | Out-File email.json -Encoding default
    aws ses send-templated-email --cli-input-json file://email.json
    if ($?) {
        Write-Host "Send email to $name Successfully"
    } else {
        Write-Host "Send email to $name Failed"
    }
}

# Get defined user and email address mapping from parameter store, it should be a json like {"Administrator":"test@test.com", "Test":"test@test.com"}
$parameter_key = "/anthony/password/rotation/users"
$user_email_mapping_list = aws ssm get-parameter --name $parameter_key
$user_email_mapping_list = $user_email_mapping_list | ConvertFrom-Json
$user_email_mapping_list = $user_email_mapping_list.Parameter.Value | ConvertFrom-Json

# Convert user and address json into a Hashtable
$parameter_store_user_map = @{}
foreach ($property in $user_email_mapping_list.PSObject.Properties) {
    $parameter_store_user_map[$property.Name] = $property.Value
}

# Define another Hashtable to store all local users in Windows server
$local_user_map = @{}
# Define a black list which means we will not change the password for these users
$ignore_account="admin", "DefaultAccount", "WDAGUtilityAccount"
# Get all local users and store them in Hashtable
$local_users = Get-LocalUser | Select name
foreach ($i in $local_users) {
    if($ignore_account -notContains $i.name) {
        $local_user_map[$i.name] = $i.name
    }
}

# Define a Hashtable to store all status for each user when changing their password
$status = @{}
# Define a function to change the password
function change_password($name) {
    try {
        # Check if the user is in the local user Hashtable, if not, write down some error message
        $local_user_exist_flag = $local_user_map[$name]
        if ($local_user_exist_flag) {
            # If the user is Administrator, we will use AWS EC2Rescure to change the password and it will store the password in Parameter Store.
            if ($username -eq "Administrator") {
                Invoke-EC2RescueResetPasswordWithParameterStore -KMSKey $kms_id
                $new_password = "an encryption value which stored in Parameter Store, and may be viewed at the following link:<br><br>https://us-east-1.console.aws.amazon.com/systems-manager/parameters/%252FEC2Rescue%252FPasswords%252F$instance_id/description?region=us-east-1"
            } else {
                # Generate a new password with special symbols
                $special_characters = @((33,35) + (36..38) + (42..44) + (60..64) + (91..94))
                $new_password = -join ((48..57) + (65..90) + (97..122) + $SpecialCharacters | Get-Random -Count 16 | foreach {[char]$_})
                $new_password_encryption = ConvertTo-SecureString $new_password -AsPlainText -Force
                $user_account = Get-LocalUser -Name $name
                $user_account | Set-LocalUser -Password $new_password_encryption
                if ($?) {
                    Write-Host "Change password for $user_account Successfully"
                } else {
                    Write-Host "Change password for $user_account Failed"
                }
            }
            $address = $parameter_store_user_map[$name]
            send_template_email $name $new_password $address "" "PasswordRotationTemplate"
            $status[$name] = "Password rotated Successfully!"
        } else {
            $status[$name] = "Local user doesn't exist, password rotated Failed!"
        }
    } catch {
        $status[$name] = "Powershell executed failed!"
    }
}

# If the option parameter is not empty, just change it. If not, change all users password
if ($username) {
    change_password $username
} else {
    foreach ($h in $parameter_store_user_map.GetEnumerator() )
    {
        change_password $h.Name
    }
}

# Reconstruct the status message with HTML styles.
foreach ($h in $status.GetEnumerator() )
{
    $key = $h.Name
    $value = $h.Value
    if ($h.Value -match "Successfully") {
        $content += "$key - $value<br>"
    } else {
        $content += "<font color=red>$key - $value</font><br>"
    }
}
# Send the final status email
send_template_email "" "" "" "$content" "PasswordRotationStatusTemplate"