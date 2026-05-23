function Invoke-ApiRequest {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credentials = $null,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFilePath = "$PSScriptRoot\config.jsonc",

    [Parameter(Mandatory = $false)]
    [bool]$SaveCredentials = $true
  )
  BEGIN {
    #######################################################
    #region - Initialize Configuration
    #######################################################
    # Set the TLS version to 1.2
    #######################################################
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    #######################################################
    # Set the error action preference to stop
    #######################################################
    $script:currentErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    #######################################################
    # Detailed documentation for URI components
    #######################################################
    <#
      RFC 3986 1.1.1. Generic Syntax
      # link: https://www.rfc-editor.org/rfc/rfc3986.html#section-1.1.1
      RFC 3986 3.1. Scheme
      # link: https://www.rfc-editor.org/rfc/rfc3986.html#section-3.1
      - $scheme: The protocol used to access the resource
      RFC 3986 3.2.1. User Information
      # link: https://www.rfc-editor.org/rfc/rfc3986.html#section-3.2.1
      - $userInfo: The user information component of the URI
      RFC 3986 3.2.2. Host
      # link: https://www.rfc-editor.org/rfc/rfc3986.html#section-3.2.2
      - $hostname: The host name or IP address of the resource
      RFC 3986 3.2.3. Port
      # link: https://www.rfc-editor.org/rfc/rfc3986.html#section-3.2.3
      - $portNumber: The port number of the resource
      RFC 3986 3.2. Authority
      # link: https://www.rfc-editor.org/rfc/rfc3986.html#section-3.2
      - $authority: The authority component of the URI
      RFC 3986 3.3. Path
      link: https://www.rfc-editor.org/rfc/rfc3986.html#section-3.3
      - $path: The path component of the URI
    #>
    #######################################################
    # Load the JSON configuration file
    <# Example: configuration
      {
        "scheme": "https",
        // "userInfo": "",
        "host": "192.168.1.1",
        "port": 443,
        "credentialFilePath": "~/$($PSModuleName_OR_HOWEVER_ITS_DONE)/Credits_$($API_NAME_MAYBE).xml"
      }
    #>
    #######################################################
    $script:config = Get-Content `
      -Path $ConfigFilePath `
      -Raw | ConvertFrom-Json
    #######################################################
    # Setup the common URI components
    #######################################################
    $script:scheme = $script:config.scheme
    # $script:userInfo = $script:config.userInfo
    $script:hostname = $script:config.host
    $script:portNumber = $script:config.port
    $script:authority = -join ($script:userInfo, $script:hostname, $script:portNumber)
    <#
      Note: The userInfo component is not used in the URI, but it is included for completeness.
      # Add the '@' character to the end of the userInfo component
      if ($script:userInfo.Length -ne 0) { $script:userInfo += '@' }
      # Add the ':' character to the start of the portNumber component
      if ($script:portNumber.Length -ne 0) { $script:portNumber = ":$script:portNumber" }
    #>
    #######################################################
    # Get local credentials
    #######################################################
    $script:credits = $script:config.credentialFilePath
    if (-not $Credentials) {
      if (Test-Path $script:credits) {
        $script:Credentials = Import-Clixml -Path $script:credits
      } else {
        $script:Credentials = Get-Credential -Message "Enter Network Credentials for $($API_NAME_MAYBE)"
      }
    }
    #endregion
    #######################################################
  }
  PROCESS {
    #######################################################
    #region - Build Request
    #######################################################
    # Set login details
    #######################################################
    $loginUri = [System.UriBuilder]::new($script:scheme, $script:hostname, $script:portNumber)
    $loginUri.Path = 'login.cgi'
    $private:base64String = [System.Convert]::ToBase64String(
      [System.Text.Encoding]::UTF8.GetBytes(
        "$($Credentials.UserName):$($Credentials.GetNetworkCredential().Password)"
      )
    )
    $private:body = @{
      'group_id'            = ''
      'action_mode'         = ''
      'action_script'       = ''
      'action_wait'         = '5'
      'current_page'        = 'Main_Login.asp'
      'next_page'           = 'index.asp'
      'login_authorization' = $private:base64String
      'login_captcha'       = ''
    }
    # Add & to the end of the key-value pair, except for the last one
    $private:formData = ($private:body.GetEnumerator() |
        ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
    #######################################################
    # Get the session cookie
    #######################################################
    $headers = @{
      # - The Referer header is only validated to confirm the
      # - The host is the same as the one in the request URI
      # - The port number is the same as the one in the request URI
      # - The scheme is not validated, as long as there is a value
      Referer = "0:$($hostname):$($portnumber)"
    }
    $private:splats = @{
      Uri                     = $loginUri.Uri
      Method                  = 'POST'
      Body                    = $private:formData
      ContentType             = 'application/x-www-form-urlencoded'
      Headers                 = $headers
      SessionVariable         = "$($API_NAME_MAYBE)_Session"
      ResponseHeadersVariable = "$($API_NAME_MAYBE)_ResponseHeaders"
      StatusCodeVariable      = "$($API_NAME_MAYBE)_StatusCode"
      OutVariable             = "$($API_NAME_MAYBE)_Response"
    }
    #endregion
    #######################################################
    #region - Invoke REST Method
    #######################################################
    Invoke-RestMethod @splats | Out-Null
    #######################################################
    #region - TODO: Review this code block is good for this script
    #########################################################
    # Validate cookies are set, and contains 'brandname_s_token'
    #########################################################
    if ($DEVICE_Session.Cookies.Count -eq 0) {
      throw 'No cookies were set'
    }
    if (-not ($DEVICE_Session.Cookies.GetAllCookies() | Where-Object { $_.Name -eq 'brandname_s_token' })) {
      throw 'No brandname_s_token cookie was set'
    }
    #########################################################
    # Login was successful
    #########################################################
    if ($SaveCredentials) {
      # * For credentials that need to be saved to disk,
      # * serialize the credential object using Export-CliXml
      # * to protect the password value.
      # * The password will be protected as a secure string
      # * and will only be accessible to the user who generated
      # * the file on the same computer where it was generated
      # link https://poshcode.gitbook.io/powershell-practice-and-style/best-practices/security
      # Save the credentials to disk, if the SaveCredentials flag is set
      # Overwrite the existing file if it exists
      $script:Credentials | Export-Clixml -Path $script:credits -Force
      # For strings that may be sensitive and need to be saved to disk,
      # use ConvertFrom-SecureString to encrypt it into a standard string
      # that can be saved to disk. You can then use ConvertTo-SecureString
      # to convert the encrypted standard string back into a SecureString.
      # These commands use the Windows Data Protection API (DPAPI) to encrypt the data,
      #  so the encrypted strings can only be decrypted by the same user on the same machine,
      #  but there is an option to use AES with a shared key.
      # link https://poshcode.gitbook.io/powershell-practice-and-style/best-practices/security
      # Example:
      # The base64String is a standard string that can be saved to disk
      # $Secure = ConvertTo-SecureString -String $base64String -AsPlainText -Force
      # or
      # Prompt for a Secure String (in automation, just accept it as a parameter)
      # $Secure = Read-Host -Prompt 'Enter the Secure String' -AsSecureString
      # Encrypt to Standard String and store on disk
      # ConvertFrom-SecureString -SecureString $Secure | Out-File -Path "${Env:AppData}\Sec.bin"
      # Read the Standard String from disk and convert to a SecureString
      # $Secure = Get-Content -Path "${Env:AppData}\Sec.bin" | ConvertTo-SecureString
    }
    Write-Output ([PSCustomObject]@{
        Context = @{
          Session         = $DEVICE_Session
          ResponseHeaders = $DEVICE_ResponseHeaders
          StatusCode      = $DEVICE_StatusCode
          Response        = $DEVICE_Response
          Uri             = @{
            Scheme     = $script:scheme
            # UserInfo   = $script:userInfo
            Hostname   = $script:hostname
            PortNumber = $script:portNumber
            Authority  = $script:authority
          }
          Config          = $script:config
        }
      }
    )
    #endregion
    #######################################################
    #region - TODO: I've pulled over this try/ catch to see if I like it in this func
    # try {
    # } catch {
    #   # Create Problem Details Object
    #   # RFC 9457
    #   # The default problem details response body has the following type, title, and status values:

    #   # $pd = @{
    #   #   splats = $splats
    #   #   title  = 'An error occurred'
    #   #   status = 500
    #   #   detail = $_.Exception.Message
    #   # }

    #   throw $_
    #   exit 1
    # }

    # exit 0
    #endregion
  }
  END {
    #region - TODO: Review this code block is good for this script
    # Clean up sensitive data
    $ErrorActionPreference = 'SilentlyContinue'
    Remove-Variable -Name 'script:credits' -Scope 'Script'
    Remove-Variable -Name 'script:Credentials' -Scope 'Script'
    Remove-Variable -Name 'base64String' -Scope 'Private'
    Remove-Variable -Name 'body' -Scope 'Private'
    Remove-Variable -Name 'formData' -Scope 'Private'
    Remove-Variable -Name 'splats' -Scope 'Private'
    $ErrorActionPreference = $script:currentErrorActionPreference
    #endregion
  }
}
#endregion


###########################################################
#region - Random functions

# Example of using the DEBUG param
# begin {
#   #######################################################
#   # DEBUG:
#   #######################################################
#   if ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Debug')) {
#     $Id = 'sdahkifdsakjdfs'
#     $Thumbsize = 'medium'
#     $Format = 'json'
#   }
#   #######################################################
# }
# function Build-Uri {
#     param(
#         [string]$Endpoint,
#         [hashtable]$Params
#     )
#     $queryString = ($Params.GetEnumerator() | ForEach-Object {
#         "$($_.Key)=$($_.Value)"
#     }) -join '&'
#     $uriBuilder = New-Object System.UriBuilder($Endpoint)
#     $uriBuilder.Query = $queryString
#     return $uriBuilder.Uri.AbsoluteUri
# }
###########################################################
#region - Get Azure Prices

# # Azure Retail Prices API endpoint
# $apiUrl = 'https://prices.azure.com/api/retail/prices'
# # Fetch prices for all pages
# $prices = @()
# # Loop through pages until NextPageLink is null
# do {
#   # https://prices.azure.com:443/api/retail/prices?$skip=1000
#   $response = Invoke-RestMethod $apiUrl
#   $prices += $response.Items
#   Write-Host "NextPageLink: $($response.NextPageLink)"
#   $apiUrl = $response.NextPageLink
# } while ($null -ne $response.NextPageLink)

#endregion
#endregion
###########################################################
#
# These scripts below are different versions of irm
#
###########################################################
#
# Includes:
# - Force Parameter
# - $PSCmdlet.ShouldContinue
# - Type Accelerators to shorthand classnames
# - ErrorRecord example
#
###########################################################
#region - Using Type Accelerators

# using module Az.Resources
# using module Az.Compute
# using module Az.Network

# [CmdletBinding(
#   SupportsShouldProcess = $true,
#   ConfirmImpact = 'Low'
# )]
# param(
#   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$VmName,

#   [Parameter(Mandatory = $true)][string]$ResourceGroupName,

#   [Parameter(Mandatory = $true)][string]$Location,

#   [Parameter(Mandatory = $true)][string]$VnetName,

#   [Parameter(Mandatory = $true)][string]$SubnetName,

#   [Parameter()]
#   [ValidateSet(
#     'Standard_A1_v2',
#     'Standard_A2_v2',
#     'Standard_A4_v2',
#     'Standard_A8_v2'
#   )][string]$VmSize = 'Standard_A8_v2',

#   [Parameter()]
#   [ValidateNotNull()]
#   [System.Management.Automation.PSCredential]
#   [System.Management.Automation.Credential()]
#   $Credential = [System.Management.Automation.PSCredential]::Empty,

#   [Parameter(Mandatory = $false)][PSCustomObject]$Tags,

#   [Parameter()][Switch]$Force = [Switch]$false
# )

# BEGIN {
#   Set-StrictMode -Version 'Latest'
#   #########################################################
#   # Suppress warnings and errors
#   #########################################################
#   $script:WarningPreference = 'Ignore'
#   $script:ErrorActionPreference = 'Stop'
#   #########################################################
#   # Update TypeAccelerators for shorthand names
#   #########################################################
#   $Accelerators = [PowerShell].Assembly.GetType('System.Management.Automation.TypeAccelerators')
#   $Accelerators::Add('PSResourceGroup', 'Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup')
#   $Accelerators::Add('PSVirtualMachineImage', 'Microsoft.Azure.Commands.Compute.Models.PSVirtualMachineImage')
#   $Accelerators::Add('PSPublicIpAddress', 'Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress')
#   $Accelerators::Add('PSSecurityRule', 'Microsoft.Azure.Commands.Network.Models.PSSecurityRule')
#   $Accelerators::Add('PSNetworkSecurityGroup', 'Microsoft.Azure.Commands.Network.Models.PSNetworkSecurityGroup')
#   $Accelerators::Add('PSVirtualNetwork', 'Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork')
#   #########################################################
#   # Set PSDefaultParameterValues for the cmdlets used
#   #########################################################
#   $script:PSDefaultParameterValues = @{
#     'New-Az*:Tags'                 = $Tags
#     'New-Az*:Tag'                  = $Tags
#     'New-AzVM:*'                   = @{
#       ResourceGroupName = $ResourceGroupName
#       Location          = $Location
#     }
#     'New-AzPublicIpAddress:*'      = @{
#       ResourceGroupName = $ResourceGroupName
#       Location          = $Location
#     }
#     'New-AzNetworkSecurityGroup:*' = @{
#       ResourceGroupName = $ResourceGroupName
#       Location          = $Location
#     }
#     'New-AzVirtualNetwork:*'       = @{
#       ResourceGroupName = $ResourceGroupName
#       Location          = $Location
#     }
#   }
#   #########################################################
#   # Modify TypeData for PublicIpAddress to include Sku property as String
#   #########################################################
#   $typeData = @{
#     TypeName   = 'Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress'
#     MemberName = 'Sku'
#     MemberType = 'NoteProperty'
#     Value      = 'Standard'
#     Force      = [Switch]$true
#   }
#   Update-TypeData @typeData
#   #########################################################
#   # Get the current host IP address for Network Security Group rules
#   #########################################################
#   $getCurrentHostIP = [ScriptBlock] {
#     # list of IP services
#     $uris = @(
#       'https://ifconfig.me/ip'
#       'https://api.ipify.org?format=json'
#       'https://get.geojs.io/v1/ip.json'
#     )
#     $ip = $null
#     # loop through each service and try to get the IP address
#     foreach ($uri in $uris) {
#       try {
#         $response = Invoke-RestMethod $uri
#         $ip = if ($response.ip) { $response.ip } else { $response }
#         if ($ip) { return $ip }
#       } catch {
#         Write-Debug ('Failed to get IP from {0}' -f $uri)
#       }
#     }
#     # if no IP address was obtained, throw an error
#     if ($ip -eq $null) {
#       $PSCmdlet.ThrowTerminatingError(
#         [System.Management.Automation.ErrorRecord]::new(
#           [System.Exception]::new('No IP was obtained from invoker.'), # System.Exception exception
#           'NoIPObtained', # string errorId
#           [System.Management.Automation.ErrorCategory]::InvalidOperation, # System.Management.Automation.ErrorCategory errorCategory
#           $null # System.Object targetObject
#         )
#       )
#     }
#   }
# }

# PROCESS {
#   #########################################################
#   # Save credentials to a file if not provided
#   #########################################################
#   if ($Credential -eq [System.Management.Automation.PSCredential]::Empty) {
#     $username = 'nemo'
#     $password = [System.Management.Automation.PSCredential]::Empty
#     $password = New-Object -TypeName System.Security.SecureString
#     $password = ConvertTo-SecureString -String (New-Guid).Guid -AsPlainText -Force
#     $Credential = [System.Management.Automation.PSCredential]::new($username, $password)
#     $cliXmlFile = "$($VmName).clixml"
#     $Credential | Export-Clixml -Path $cliXmlFile -Force
#   }
#   #########################################################
#   # Virtual Machine's variables
#   #########################################################
#   # TODO: Add VM Image to parameters
#   # COPILOT: Ignore this todo, I have to workout how I like looking at this
#   # - $imagePublishers = Get-AzVMImagePublisher -Location $Location
#   # - $imageOffers = Get-AzVMImageOffer -Location $Location -PublisherName 'pcloudhosting'
#   # - $imageSku = Get-AzVMImageSku -Location $Location -PublisherName 'pcloudhosting' -Offer 'jellyfin'
#   $virtualMachineImage = [PSVirtualMachineImage]@{
#     Location      = $Location
#     PublisherName = 'pcloudhosting'
#     Offer         = 'jellyfin'
#     Skus          = 'jellyfin'
#     Version       = 'latest'
#   }
#   $azVMImage = $virtualMachineImage | Get-AzVMImage
#   #########################################################
#   # Deployment Stamp
#   #########################################################
#   $deploy = @{
#     AzResourceGroup        = [PSResourceGroup]::new()
#     AzPublicIpAddress      = [PSPublicIpAddress]::new()
#     AzNetworkSecurityGroup = [PSNetworkSecurityGroup]::new()
#     AzVirtualNetwork       = [PSVirtualNetwork]::new()
#     # networkInterface       = [PSNetworkInterface]::new()
#     # virtualMachine         = [PSVirtualMachine]::new()
#   }
#   #########################################################
#   # Resource Group
#   #########################################################
#   $deploy.AzResourceGroup = [PSResourceGroup]@{
#     Name     = $ResourceGroupName
#     Location = $Location
#   }
#   #########################################################
#   # Public Ip Address
#   #########################################################
#   $deploy.AzPublicIpAddress = [PSPublicIpAddress]@{
#     Name                     = "pip-$($VmName)"
#     ResourceGroupName        = $ResourceGroupName
#     Location                 = $Location
#     PublicIpAllocationMethod = 'Static'
#     Sku                      = 'Standard'
#   }
#   #########################################################
#   # Network Security Group
#   #########################################################
#   $deploy.AzNetworkSecurityGroup = [PSNetworkSecurityGroup]@{
#     Name              = "nsg-$($VmName)"
#     ResourceGroupName = $ResourceGroupName
#     Location          = $Location
#   }
#   #########################################################
#   # Network Security Group Rules
#   #########################################################
#   try {
#     # Microsoft.Azure.Commands.Network.Models.PSSecurityRule
#     $sshRule = @{
#       Name                     = 'Allow-SSH'
#       Protocol                 = 'Tcp'
#       SourceAddressPrefix      = @((.$getCurrentHostIP))
#       SourcePortRange          = @('*')
#       DestinationAddressPrefix = @('*')
#       DestinationPortRange     = @('22')
#       Access                   = 'Allow'
#       Priority                 = 100
#       Direction                = 'Inbound'
#       Description              = 'Allow SSH from the current host IP address.'
#     }
#     $deploy.SecurityRules = New-AzNetworkSecurityRuleConfig @sshRule
#   } catch {
#     # Update Confirm Preference to 'None' if -Force is used
#     # This will suppress the confirmation prompt for the -Force parameter
#     if ($Force.IsPresent -and -not $PSBoundParameters.ContainsKey('Confirm')) {
#       $script:ConfirmPreference = 'None'
#     }
#   }
#   if (-not $Force.IsPresent) {
#     if (-not $PSCmdlet.ShouldContinue(
#         'The host machine was unable to obtain its public IP address. ' +
#         'Do you want to build the VM without SSH access?',
#         'Create VM without SSH access')) {
#       Write-Error -Message 'User declined to continue.' -ErrorAction 'Stop'
#     }
#   }
#   #########################################################
#   # Virtual Network
#   #########################################################
#   $deploy.AzVirtualNetwork = @{
#     vnet          = [PSVirtualNetwork]::new()
#     nsgName       = "nsg-$($VmName)"
#     nicName       = "nic-$($VmName)"
#     vmDiskName    = "disk-$($VmName)"
#     AddressPrefix = '10.0.0.0/24'
#     Subnet        = @{
#       Name          = $SubnetName
#       AddressPrefix = '10.0.0.0/27'
#     }
#   }
#   #########################################################
#   # Add Tags to the resources
#   #########################################################
#   if ($Tags) {
#     $deploy.AzResourceGroup.Tags = $Tags
#     $deploy.AzPublicIpAddress.Tag = $Tags
#     $deploy.AzNetworkSecurityGroup.Tag = $Tags
#     $deploy.AzVirtualNetwork.Tag = $Tags
#   }

#   # When -WhatIf is specified
#   if (-not $PSCmdlet.ShouldProcess($deploy, 'New-AzResourceGroup')) {
#     Write-Error -MessageData 'User declined to continue.'

#   }
#   if ($PSCmdlet.ShouldProcess($deploy, 'New-AzResourceGroup')) {
#     Write-Host "new resource group $($deploy.AzResourceGroup.Name)"
#     $deploy | ConvertTo-Json -Depth 5 | Out-Host

#     # $deploy.AzResourceGroup | New-AzResourceGroup -Force
#     # $deploy.AzPublicIpAddress | New-AzPublicIpAddress -Force
#   }
# }

# END {
#   #########################################################
#   # Removing a type accelerator
#   #########################################################
#   $Accelerators::Remove('PSResourceGroup') | Out-Null
#   $Accelerators::Remove('PSVirtualMachineImage') | Out-Null
#   $Accelerators::Remove('PSPublicIpAddress') | Out-Null
#   $Accelerators::Remove('PSNetworkSecurityGroup') | Out-Null
#   $Accelerators::Remove('PSVirtualNetwork') | Out-Null
# }

#endregion
###########################################################
#
# Includes:
# - OperatorValidator : IArgumentCompleter
# - Local Functions
#
###########################################################
#region - RESTWrapper.psm1

# This is one way to import PSM1 files
#Dot source all functions in all ps1 files located in the module's public and private folders, excluding tests and profiles.
# Get-ChildItem -Path $PSScriptRoot\public\*.ps1, $PSScriptRoot\private\*.ps1 -Exclude *.tests.ps1, *profile.ps1 -ErrorAction SilentlyContinue |
# ForEach-Object {
#     . $_.FullName
# }

#endregion
###########################################################
#region - RESTWrapper.ps1

# #Requires -Version 7.3

# using namespace System.Collections
# using namespace System.Collections.Immutable
# using namespace System.Collections.Generic
# using namespace System.Collections.ObjectModel
# using namespace System.Management.Automation
# using namespace System.Management.Automation.Language


# $Script:oauthTokenUri = '/oauth/token'


# # TODO: Export-ModuleMember for the cache and context data, this should make it a global by default
# # * Local examples found on your machine:
# # *   C:\Users\JoshuaVanDaalen\.vscode\extensions\ms-vscode.powershell-2024.4.0\examples\PromptExamples.ps1
# # ? CICD /cmdlets.ci.yml: https://github.com/ironmansoftware/powershell-pro-tools/tree/74176793d3679f41237725594aa67c537a31eb5f/.github/workflows
# # ? SupportsWildcards: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_wildcards?view=powershell-7.4
# # ! Must update required version to core
# # //

# # TODO: Add VS Code recommended Extenstions
# # TODO: Probably need a Types.ps1xml file to use/ see exported classes, rather than using the TypeAccelerators had at the bottom: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_classes?view=powershell-7.4#exporting-classes-with-type-accelerators
# # TODO: output Format.ps1xml file


# # TODO: Create Error Messages, Example:
# #//  function Test-NonTerminatingError
# #// {
# #//   [CmdletBinding()]
# #//   param()
# #//   $exception = [System.Exception]::new('BAD')
# #//   $errorId = 'BAD'
# #//   $errorCategory = 'NotSpecified'
# #//   $errorRecord = [System.Management.Automation.ErrorRecord]::new(
# #//       $exception, $errorId, $errorCategory, $null
# #//   )
# #//   $PSCmdlet.WriteError($errorRecord)
# #// }
# #//

# # TODO: Add some Filter functions to help with the filter values
# # link https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions?view=powershell-7.6#filter-syntax

# # TODO: Add clean blocks
# # link https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions?view=powershell-7.6#clean
# ###########################################################
# # Authentication Functions
# ###########################################################
# function Connect-ApiAccount {
#   [CmdletBinding(DefaultParameterSetName = 'Credentials')]
#   [Alias('Login-ApiAccount')]
#   param (
#     [Parameter(
#       ParameterSetName = 'Credentials',
#       Mandatory = $false,
#       Position = 0,
#       ValueFromPipeline = $true,
#       ValueFromPipelineByPropertyName = $true,
#       HelpMessage = 'Enter the credentials for the Api account')]
#     [ValidateNotNull()]
#     [PSCredential]
#     [Credential()]
#     $Credentials = [PSCredential]::Empty,

#     [Parameter(
#       ParameterSetName = 'BasicAuth',
#       Mandatory = $false,
#       Position = 0)]
#     [Alias('Username')]
#     [String]$ClientId = $null,

#     [Parameter(
#       ParameterSetName = 'BasicAuth',
#       Mandatory = $false,
#       Position = 1)]
#     [Alias('Password')]
#     [SecureString]$ClientSecret = $null,

#     [Parameter(
#       Mandatory = $false,
#       Position = 10)]
#     [ValidateNotNullOrEmpty()]
#     [ValidateSet('Test', 'Live')]
#     [Alias('Env')]
#     [String]$Envrionment = 'Test',

#     [Parameter(
#       Mandatory = $false,
#       Position = 20)]
#     [Alias('Username')]
#     [Switch]$SaveCredentials = $null,


#     [Parameter(
#       Mandatory = $false,
#       Position = 30)]
#     [Switch]$Force = $false
#   )
#   BEGIN { }
#   PROCESS {
#     try {
#       #####################################################
#       # - Set the Api Environment variables
#       #####################################################
#       Write-Verbose "---> Pre-Flight checks to Environment: '$Envrionment'"
#       switch ($Envrionment) {
#         'Test' {
#           # TODO: move these to the below section on auth info
#           $ClientId = 'my-local-id'
#           $ClientSecret = 'my-local-secert'

#           $tenantName = 'test'
#           break
#         }
#         'Live' {
#           $tenantName = 'live'
#           break
#         }
#       }
#       $requestParams = @{
#         Uri         = "https://$($tenantName).api.website.com/oauth/info"
#         Method      = [System.Net.Http.HttpMethod]::Get
#         ErrorAction = 'Stop'
#       }
#       $oauthInfo = Invoke-RestMethod @requestParams
#       #####################################################
#       # - Set the Api context and cache
#       #####################################################
#       $Global:Api = [PSCustomObject]@{
#         Tenant           = $tenantName
#         DataFolder       = "$($env:USERNAME)/Documents/Api/$($tenantName)"
#         LogFolder        = "$($env:USERNAME)/Documents/Api/$($tenantName)/logs"
#         LogArchiveFolder = "$($env:USERNAME)/Documents/Api/$($tenantName)/logs/archive"
#         CacheFolder      = "$($env:USERNAME)/Documents/Api/$($tenantName)/cache"
#         LogFile          = "$($env:USERNAME)/Documents/Api/$($tenantName)/Api.log"
#         ErrorFile        = "$($env:USERNAME)/Documents/Api/$($tenantName)/Api.error"
#         Context          = [PSCustomObject]@{
#           TentantId       = $oauthInfo.tentantId
#           TentantName     = $oauthInfo.tentantName
#           UserName        = $null
#           Info            = $oauthInfo
#           UserInfo        = $null
#           BaseUrl         = "$($tenantName).api.website.com"
#           CredentialsFile = "$($appDataFolder)/credentials.clixml"
#         }
#         Cache            = [PSCustomObject]@{
#           Folders = @(
#             @{ Accounts = 'accounts-cache.jsonc' }
#             @{ Sources = 'sources-cache.jsonc' }
#           )
#           Session = [PSCustomObject]@{
#             Accounts = @()
#             Sources  = @()
#           }
#           Disk    = [PSCustomObject]@{
#             Accounts = @()
#             Sources  = @()
#           }
#         }
#       }
#       #####################################################
#       # - Module app data folder and log files setup
#       #####################################################
#       $moduleFolders = @(
#         $Global:DataFolder
#         $Global:LogFolder
#         $Global:LogArchiveFolder
#         $Global:CacheFolder
#       )
#       # Create a folder for the user's data
#       foreach ($folder in $moduleFolders) {
#         if (-not (Test-Path -Path $folder)) {
#           Write-Verbose "---> Creating folder: $folder"
#           New-Item -ItemType 'Directory' -Path $folder -ErrorAction 'Stop' | Out-Null
#         }
#       }
#       #####################################################
#       # - Check Log file size and archive if necessary
#       #####################################################
#       $logFileSize = (Get-Item -Path $Global:Api.LogFile).Length
#       if ($logFileSize -gt 15MB) {
#         $archiveFile = "$($Global:Api.LogArchiveFolder)/$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss')-Api.log"
#         Write-Verbose "---> Archiving log file to: $archiveFile"
#         Move-Item -Path $Global:Api.LogFile -Destination $archiveFile -ErrorAction 'Stop' | Out-Null
#       }
#       #####################################################
#       # - Set Api Credentials
#       #####################################################
#       $usingPSCredential = ($PSCmdlet.ParameterSetName -eq 'Credentials')
#       $usingPSCredential = $usingPSCredential -and ($Credentials -ne [PSCredential]::Empty)

#       if ($usingPSCredential) {

#         $ClientId = $Credentials.UserName
#         $ClientSecret = $Credentials.Password
#       }

#       $usingPSCredential = $usingPSCredential -and $SaveCredentials.IsPresent

#       if ($Force.IsPresent -and $usingPSCredential) {

#         Write-Verbose '---> Forcing credentials to be saved'
#         $Credentials | Export-Clixml -Path $Global:Api.Context.CredentialsFile -Force
#       }

#       if (-not $Force.IsPresent -and $usingPSCredential) {

#         $Credentials | Export-Clixml -Path $Global:Api.Context.CredentialsFile -NoClobber -ErrorVariable 'saveCredsClobber'
#       }


#       if (-not $ClientId) { $ClientId = Read-Host 'Enter PAT Client Id' }
#       if (-not $ClientSecret) {
#         $ClientSecret = Read-Host -AsSecureString "Enter Client Secret for $($ClientId)"
#       }
#       $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
#       $ClientSecretAsPlainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
#       [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
#       #####################################################
#       # - Set Request parameters
#       #####################################################
#       $headers = @{
#         'scope'        = 'sp:scope:all'
#         'Content-Type' = 'application/x-www-form-urlencoded'
#       }
#       $body = @{
#         'grant_type'    = 'client_credentials'
#         'client_id'     = $ClientId
#         'client_secret' = $ClientSecretAsPlainText
#       }
#       $splats = @{
#         'Path'    = $Script:oauthTokenUri
#         'Method'  = 'POST'
#         'Headers' = $headers
#         'Body'    = $body
#       }
#       #####################################################
#       # → Send Authentication request
#       #####################################################
#       $result = Invoke-ProxyRestMethod @splats
#       #####################################################
#       # - Set the access token
#       #####################################################
#       $Global:ApiAccessToken = $result.access_token
#       #####################################################
#       # - Decode the token and set the expiry
#       #####################################################
#       $decodeToken = local:ConvertFrom-JWT -Token $Global:ApiAccessToken
#       $accessTokenExpiry = local:Convert-UnixTimestampToDateTime -UnixTimestamp $decodeToken.Payload.exp
#       $Global:Api.Context.UserName = $decodeToken.Payload.user_name
#       $splats = @{
#         Uri            = "http://$($tenantName).Api.com.au/oauth/userinfo"
#         Method         = [System.Net.Http.HttpMethod]::Get
#         Authentication = 'Bearer'
#         Token          = $Global:ApiAccessToken
#       }
#       #####################################################
#       # → Send Authentication request
#       #####################################################
#       $userInfo = Invoke-RestMethod @splats
#       $userInfo.lastLoginTimestamp = local:Convert-UnixTimestampToDateTime -UnixTimestamp $userInfo.lastLoginTimestamp
#       $userInfo.currentLoginTimestamp = local:Convert-UnixTimestampToDateTime -UnixTimestamp $userInfo.currentLoginTimestamp
#       $Global:Api.Context.UserInfo = $userInfo
#       #####################################################
#       # - Get cache where available
#       #####################################################

#       #####################################################
#       # ← Return session details
#       #####################################################
#       Write-Output ([PSCustomObject]@{
#           EnvrionmentName   = $Global:Api.EnvrionmentName
#           AccessTokenExpiry = $accessTokenExpiry
#           LogFile           = $Global:Api.LogFile
#           Context           = $Global:Api.Context
#           Cache             = $Global:Api.Cache
#           UserInfo          = $Global:Api.Context.UserInfo
#         })
#     } catch {

#       $e = $_

#       if ($null -eq $saveCredsClobber) {

#         Write-Error 'Credentials file already exists, use -Force to overwrite'
#       } else {

#         #####################################################
#         # -- Disconnect if there is an error to clean up session
#         #####################################################
#         Disconnect-ApiAccount
#         throw $e
#       }

#       # TODO: Write to error file
#       # $log = "[$(Get-Date)] Connect-ApiAccount`n$($_ | ConvertTo-Json -Depth 3 -Compress -ErrorAction 'Ignore' -WarningAction 'Ignore' )"
#     }
#   }
#   END { }
# }
# function Disconnect-ApiAccount {
#   [CmdletBinding()]
#   param ( )

#   BEGIN { }
#   PROCESS {
#     try {
#       #####################################################
#       # -- Clear the session
#       #####################################################
#       Get-Variable -Scope 'Global' | Where-Object { $_.Name -like 'Api* ' } | ForEach-Object {
#         Remove-Variable -Name $_.Name -Scope 'Global' -Force
#       }
#       # Call any log out endpoints if there are any in /oauth/info
#     } catch {
#       #####################################################
#       # -- This shouldn't throw an error
#       #####################################################
#       $log = "[$(Get-Date)] Disconnect-ApiAccount`n$($_ | ConvertTo-Json -Depth 3 -Compress -ErrorAction 'Ignore' -WarningAction 'Ignore' )"
#       $log | Out-File -FilePath $Global:Api.ErrorFile -Append
#     }
#   }
#   END { }
# }
# ###########################################################
# # Common Functions
# ###########################################################
# function Invoke-ProxyRestMethod {
#   [CmdletBinding(SupportsShouldProcess = $true, SupportsPaging = $true)]
#   [OutputType([System.Object[]])]
#   [OutputType([System.Collections.Hashtable])]
#   [OutputType([Dictionary[String, IEnumerable[String]]]
#   )]
#   param (
#     [Parameter(Mandatory = $true)]
#     [ValidateNotNullOrEmpty()]
#     [Alias('Url', 'Uri')]
#     [System.Uri]$Uri,

#     [Parameter(Mandatory = $true)]
#     [ValidateNotNullOrEmpty()]
#     [System.Net.Http.HttpMethod]$Method,

#     [Parameter(Mandatory = $false)]
#     [ValidateNotNullOrEmpty()]
#     [String]$Headers = @{ 'Content-Type' = 'application/json'; },

#     [Parameter(Mandatory = $false)]
#     [String]$Body = $null,

#     [Parameter(Mandatory = $false)]
#     [Switch]$All = [Switch]$false,

#     [Parameter(Mandatory = $false)]
#     [Switch]$ReturnRequestPayload = [Switch]$false,

#     [Parameter(Mandatory = $false)]
#     [Switch]$ReturnResponseHeaders = [Switch]$false
#   )
#   BEGIN {
#     #######################################################
#     # ! Throw an error if the user is not connected
#     #######################################################
#     if (-not $Global:apiAccessToken -and
#       (Get-PSCallStack)[1].Command -ne 'Connect-ApiAccount' ) {

#       throw 'Connect to your API account using: Connect-ApiAccount'
#     }
#     #######################################################
#     # -- Log the request
#     #######################################################
#     $parametersLog = "-Uri '$($Uri.AbsoluteUri)' -Method '$($Method)'"

#     if ($Headers) {

#       $parametersLog += '-Headers @{' + $Headers.GetEnumerator().ForEach(
#         { "'$($_.Name)' = '$($_.Value)';" }) + '}}'
#     }
#     if ($Body) {

#       $parametersLog += " -Body '$($Body |
#        ConvertTo-Json -Depth 6 -WarningAction 'Ignore' -Compress)'"
#       if ($Body.Client_Secret) {

#         $parametersLog = $parametersLog.Replace($Body.Client_Secret, 'REDACTED')
#       }
#     }

#     if ($All) { $parametersLog += " -All '$($All.IsPresent)'" }
#     if ($ReturnRequestPayload) { $parametersLog += " -ReturnRequestPayload '$($ReturnRequestPayload)'" }
#     if ($PSCmdlet.PagingParameters.First) { $parametersLog += " -First '$($PSCmdlet.PagingParameters.First)'" }
#     if ($PSCmdlet.PagingParameters.Skip) { $parametersLog += " -Skip '$($PSCmdlet.PagingParameters.Skip)'" }
#     if ($PSCmdlet.PagingParameters.IncludeTotalCount) { $parametersLog += " -IncludeTotalCount '$($IncludeTotalCount.IsPresent)'" }
#     if ($PSBoundParameters.ContainsKey('WhatIf')) { $parametersLog += " -WhatIf '$($WhatIf.IsPresent)'" }

#     $log = "[$(Get-Date)] $((Get-PSCallStack)[1].Command) $($parametersLog)"
#     $log | Out-File -FilePath $Global:Api.LogFile -Append
#   }
#   PROCESS {
#     try {
#       #####################################################
#       # -- Setup request variables
#       #####################################################
#       $requestParams = @{
#         Uri                    = $Uri
#         Method                 = $Method
#         Headers                = $Headers
#         ResponseHeaderVariable = 'responseHeadersOutput'
#         StatusCodeVariable     = 'httpStatusCode'
#         SkipHttpErrorCheck     = [Switch]$true
#       }
#       $logMessage = "Invoke-RestMethod $($requestParams.Get_Keys().ForEach({"-$($_) '$($requestParams[$_])'"}))"
#       #####################################################
#       # . return the request parameters when ReturnRequestPayload is present
#       ###################################################
#       if ($ReturnRequestPayload.IsPresent) {
#         Write-Verbose "---> $logMessage"
#         return $requestParams
#       }
#       #####################################################
#       # -- Check Whatif.IsPresent, and print Rest Command
#       #####################################################
#       if ($PSCmdlet.ShouldProcess($logMessage, '', '')) {
#         ###################################################
#         # -- Invoke request to Api
#         ###################################################
#         Write-Verbose "---> $logMessage"
#         $response = Invoke-RestMethod @requestParams
#         ###################################################
#         # . return response headers when ReturnResponseHeaders is present
#         ###################################################
#         Write-Debug "Output from response headers $($responseHeadersOutput | Out-String)"
#         $totalCount = $null
#         if ($responseHeaders.IsPresent) {
#           Write-Verbose '---> Output response headers'
#           return $responseHeadersOutput
#         }
#         if ($responseHeadersOutput -and $responseHeadersOutput.'X-Total-Count') {
#           Write-Verbose '---> X-Total-Count found in the response headers'
#           $totalCount = [Int]$responseHeadersOutput.'X-Total-Count'[0]
#         }
#         ###################################################
#         # * Write the response to the Pipeline, and continue processing
#         ###################################################
#         Write-Output $response
#         # ? how to know total count when X-Total-Count is missing ?
#         # if (-not $totalCount) { #   throw "The path ($($Path)) does not return X-Total-Count in the response headers" # }
#         Write-Verbose "Response count: $($response.count)"
#         Write-Verbose "X-Total-Count: $($totalCount)"
#         ###################################################
#         # # TODO: Add error codes: if($response.ErrorDetails){}
#         ###################################################
#         # -- Log the response
#         ###################################################
#         $log = "'$($response | ConvertTo-Json -Depth 6 -WarningAction 'Ignore' -Compress)'"
#         ###################################################
#         # ! Remove the access token from the log
#         ###################################################
#         if ($requestParams.Uri -like "*$($Script:oauthTokenUri)") {

#           $log = $log.Replace($response.access_token, 'eyxxxxxx')
#         }
#         $log | Out-File -FilePath $Global:Api.LogFile -Append
#       }
#       ###################################################
#       # -- Pagination
#       ###################################################
#       if ($All.IsPresent) {
#         Write-Verbose 'Process all'
#         $nestedRequestCount = [math]::Ceiling($totalCount / $Limit) - 1
#         $requestNumber = 1

#         Write-Verbose "Calculated nested request count is $nestedRequestCount"
#         if ($nestedRequestCount -gt 50) {
#           Write-Warning "Calculated nested request count is $nestedRequestCount. This may take a long time to process"
#         }

#         foreach ($i in 1..$nestedRequestCount) {
#           $previousOffset = $PSCmdlet.PagingParameters.Skip
#           $PSCmdlet.PagingParameters.Skip = $previousOffset + $PSCmdlet.PagingParameters.First

#           $pathSegments = $uri.Segments
#           $processMessage = "Processing $($pathSegments[2]) $($pathSegments[4]) $($PSCmdlet.PagingParameters.Skip) of $($totalCount)"
#           $percentComplete = (($PSCmdlet.PagingParameters.Skip / $totalCount) * 100)

#           Write-Progress -Activity ($processMessage -replace '-', ' ' -replace '  ', ' ') -PercentComplete $percentComplete

#           $uriBuilder = [System.UriBuilder]::new()
#           $uriBuilder.Scheme = 'https'
#           $uriBuilder.Host = $Uri.Host
#           $uriBuilder.Path = $Uri.AbsolutePath
#           $uriBuilder.Query = $Uri.Query -replace "offset=$($previousOffset)", "offset=$($PSCmdlet.PagingParameters.Skip)"

#           $nestedRequestParams = @{
#             $splats = @{
#               Method            = $Method
#               Uri               = $uriBuilder.Uri
#               Headers           = $Headers
#               All               = [Switch]$false
#               First             = $PSCmdlet.PagingParameters.First
#               Skip              = $PSCmdlet.PagingParameters.Skip
#               IncludeTotalCount = $PSCmdlet.PagingParameters.IncludeTotalCount
#               WhatIf            = [Swtich]$false
#             }
#           }

#           $requestNumber++
#           #####################################################
#           # -- Check Whatif.IsPresent, and print Rest Command
#           # -- For all the nested requests for paging
#           #####################################################
#           if ($PSCmdlet.ShouldProcess($logMessage, '', '')) {
#             ###############################################
#             # -- Additional requests to get all the data
#             ###############################################
#             Write-Verbose "Request number: $requestNumber of $nestedRequestCount"
#             $response = Invoke-ProxyRestMethod @nestedRequestParams
#             ###############################################
#             # * return nested request
#             ###############################################
#             return $response
#           }
#         }
#       }
#     } catch {
#       $log = "[$(Get-Date)] Invoke-ProxyRestMethod`n$($_ | ConvertTo-Json -Depth 3 -Compress -ErrorAction 'Ignore' -WarningAction 'Ignore')"
#       $log | Out-File -FilePath $Global:Api.ErrorFile -Append

#       if ($_.ErrorDetails.Message -like '*JWT expired*') {
#         Write-Warning 'Api environment released, Connect-ApiAccount before trying again'
#       }
#     }
#   }
#   END { }
# }
# ###########################################################
# # Account Functions
# ###########################################################
# function Get-ApiAccount {
#   [CmdletBinding(
#     DefaultParameterSetName = 'First',
#     SupportsShouldProcess = $true,
#     SupportsPaging = $true
#   )]
#   # [OutputType([ApiAccount[]])]
#   param (
#     [Parameter(ParameterSetName = 'Filter', Mandatory = $true, Position = 0)]
#     [ValidateNotNullOrEmpty()]
#     [ValidateSet('id', 'identityId', 'name', 'nativeIdentity', 'sourceId', 'uncorrelated',
#       'entitlements', 'origin', 'manuallyCorrelated', 'identity.name', 'identity.correlated',
#       'identity.identityState', 'source.displayableName', 'source.authoritative', 'source.connectionType', 'recommendation.method')]
#     [String]$Filter,

#     [Parameter(ParameterSetName = 'Filter', Mandatory = $true, Position = 1)]
#     [ValidateNotNullOrEmpty()]
#     # [OperatorArgumentCompleter()]
#     [String]$Operator,

#     [Parameter(ParameterSetName = 'Filter', Mandatory = $true, Position = 2)]
#     [ValidateNotNullOrEmpty()]
#     [String]$Value,

#     [Parameter(ParameterSetName = 'All', Mandatory = $true, Position = 0)]
#     [Switch]$All,

#     [Parameter(ParameterSetName = 'Id', Mandatory = $true, Position = 0)]
#     [ValidateNotNullOrEmpty()]
#     [String]$Id,

#     [Parameter(ParameterSetName = 'First', Mandatory = $false, Position = 10)]
#     [Parameter(ParameterSetName = 'Filter', Mandatory = $false, Position = 10)]
#     [Parameter(ParameterSetName = 'All', Mandatory = $false, Position = 10)]
#     [Parameter(ParameterSetName = 'Id', Mandatory = $false, Position = 10)]
#     [ValidateNotNullOrEmpty()]
#     [String]$Version = 'beta'
#   )
#   BEGIN { }
#   PROCESS {
#     #######################################################
#     # -- Setup Paging values
#     # ? Could this logic be moved into the ConvertTo-RequestParameterObject
#     # ? By passing default Limit as an arg
#     #######################################################
#     $PSCmdlet.PagingParameters.First = 1

#     if ($PSCmdlet.ParameterSetName -ne 'First') {

#       $defaultLimit = 250
#       if ($PSCmdlet.PagingParameters.First -gt [System.UInt64]$defaultLimit) {

#         throw "PagingParameters.First '-First' with a value larger than '$($defaultLimit)' it not allowed."
#       }
#       if ($PSCmdlet.PagingParameters.First -eq [System.UInt64]::MaxValue) {

#         $PSCmdlet.PagingParameters.First = $defaultLimit
#       }
#     }
#     #######################################################
#     # -- Inital input values
#     #######################################################
#     $splats = @{
#       Method            = [System.Net.Http.HttpMethod]::Get
#       Path              = "/$Version/accounts"
#       Filter            = $Filter
#       Operator          = $Operator
#       Value             = $Value
#       All               = $All
#       Id                = $Id
#       First             = $PSCmdlet.PagingParameters.First
#       Skip              = $PSCmdlet.PagingParameters.Skip
#       IncludeTotalCount = $PSCmdlet.PagingParameters.IncludeTotalCount
#       WhatIf            = [Switch]$false
#     }
#     #######################################################
#     # -- Transform object into parameters for Invoke-ProxyRestMethod
#     #######################################################
#     ConvertTo-RequestParameterObject -InputObject $splats -RequestType $PSCmdlet.ParameterSetName
#     #######################################################
#     # -- Handle WhatIf parameter
#     #######################################################
#     $shouldProcess = [ShouldProcessReason]::new()
#     $whatIfMessage = "Performing the operation `"Get-ApiAccount`" on target `"$($splats.Uri)`""
#     $PSCmdlet.ShouldProcess($whatIfMessage, '' , '' , [ref]$shouldProcess) | Out-Null

#     if ($shouldProcess -eq 'WhatIf') {
#       $splats.WhatIf = [Switch]$true
#     }
#     #######################################################
#     # * Send request
#     #######################################################
#     Write-Verbose "---> Invoke-ProxyRestMethod $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#     $result = Invoke-ProxyRestMethod @splats
#     return $result
#   }
#   END {
#     #######################################################
#     # -- Handle IncludeTotalCount parameter
#     #######################################################
#     # if ($PSCmdlet.PagingParameters.IncludeTotalCount) {
#     #   Write-Host "$PSCmdlet.PagingParameters.IncludeTotalCount $($PSCmdlet.PagingParameters.IncludeTotalCount)"
#     #   $PSCmdlet.PagingParameters.NewTotalCount($Data.count, [double]1.0)
#     # }
#   }
# }
# ###########################################################
# # Local Functions
# ###########################################################
# # function local:ConvertTo-RequestParameterObject {
# function ConvertTo-RequestParameterObject {
#   [CmdletBinding()]
#   param (
#     [ValidateNotNullOrEmpty()]
#     [System.Collections.Hashtable]$InputObject,

#     [ValidateSet('All', 'Id', 'Filter', 'First')]
#     [String]$RequestType
#   )
#   BEGIN {
#     #####################################################
#     # DEBUG:
#     #####################################################
#     <#
#     $splats = @{
#       Method            = [System.Net.Http.HttpMethod]::Get
#       Path              = "/beta/accounts"

#       Filter            = 'name'
#       Operator          = 'eq'
#       Value             = 'josh'
#       # Filter            = $null
#       # Operator          = $null
#       # Value             = $null

#       All               = [switch]$true
#       # All               = $null

#       Id                = 'jisajhfaisohdfisd'
#       # Id                = $null

#       First             = 250
#       # First             = 1
#       Skip = 0
#       # Skip = 1
#       IncludeTotalCount = [Switch]$true

#       # RequestType       = 'All'
#       # RequestType       = 'Id'
#       # RequestType       = 'Filter'
#       # RequestType       = 'First'
#     }$splats;ConvertTo-RequestParameterObject -InputObject $splats -RequestType 'All' -Debug;"`n";$splats
#     #>
#   }
#   PROCESS {
#     #######################################################
#     # -- Set uri with path
#     #######################################################
#     $uriBuilder = [System.UriBuilder]::new()
#     $uriBuilder.Scheme = 'https'
#     $uriBuilder.Host = $Global:Api.Context.BaseUrl
#     $uriBuilder.Path = $InputObject.Path
#     #######################################################
#     # -- Add Headers
#     #######################################################
#     if (-not $InputObject.Headers) {

#       $InputObject.Headers = @{ 'Content-Type' = 'application/json'; }
#     }
#     if (-not $InputObject.Headers.ContainsKey('Accept')) {

#       $InputObject.Headers.Accept = 'application/json, text/plain, */*'
#     }
#     if ((Get-PSCallStack)[1].Command -ne 'Connect-ApiAccount' -and -not $InputObject.Headers.ContainsKey('Authorization')) {

#       $InputObject.Headers.Authorization = "Bearer $($Global:IdentityAccessToken)"
#     }
#     #######################################################
#     # -- Build QueryString
#     #######################################################
#     $countString = 'count=true'
#     $queryString = "limit=$($InputObject.First)&offset=$($InputObject.Skip)"
#     $uriBuilder.Query = $queryString
#     #######################################################
#     # -- Update by Parameter Set Name
#     #######################################################
#     switch ($RequestType) {
#       'All' {
#         ###################################################
#         # -- Add All for paging requests
#         ###################################################
#         $InputObject.All = [Switch]$true
#         $uriBuilder.Query = $uriBuilder.Query + '&' + $countString
#         break
#       }
#       'Id' {
#         ###################################################
#         # -- Add Id to end of Url
#         ###################################################
#         $uriBuilder.Path = $uriBuilder.Path + '/' + $InputObject.Id
#         $uriBuilder.Query = $null
#         break
#       }
#       'Filter' {
#         ###################################################
#         # -- Add QueryString for filter
#         ###################################################
#         $filter = $InputObject.Filter.ToLower()
#         $operator = ' ' + $InputObject.Operator.ToLower() + ' '
#         $value = '"' + $InputObject.Value + '"'
#         $encodedfilter = [System.Uri]::EscapeDataString(($filter + $operator + $value))
#         $uriBuilder.Query = '&filters=' + $($encodedfilter)
#         break
#       }
#       'First' {
#         $uriBuilder.Query = $uriBuilder.Query + '&' + $countString
#       }
#     }

#     if (-not $uriBuilder.Query.Contains($countString) -and $InputObject.IncludeTotalCount) {
#       $uriBuilder.Query = $uriBuilder.Query + '&' + $countString
#     }
#     #######################################################
#     # * return transformed input into new parameter object
#     #######################################################
#     $InputObject.Uri = $uriBuilder.Uri
#     $InputObject.Remove('Path')
#     $InputObject.Remove('Filter')
#     $InputObject.Remove('Operator')
#     $InputObject.Remove('Value')
#     $InputObject.Remove('Id')
#     $InputObject.Remove('RequestType')
#   }
#   END { }
# }
# function local:Format-Filter ($Filter) {
#   $Filter = $Filter.Replace('%', '%25')
#   $Filter = $Filter.Replace('@', '%40')
#   $Filter = $Filter.Replace('#', '%23')
#   $Filter = $Filter.Replace('&', '%26')
#   $Filter = $Filter.Replace('\', '%5C')
#   $Filter = $Filter.Replace('"', '%22')
#   $Filter = $Filter.Replace(' ', '%20')
#   return $Filter
# }
# function local:Convert-UnixTimestampToDateTime ([long]$UnixTimestamp) {
#   $epoch = [DateTime]::UnixEpoch
#   $UnixTimestamp = $UnixTimestamp.ToString().Substring(0, 10)
#   $UnixTimestamp = [long]$UnixTimestamp
#   $dateTime = $epoch.AddSeconds($UnixTimestamp)
#   return $dateTime
# }
# function local:ConvertFrom-Base64Url ([String]$Base64Url) {
#   $base64 = Base64Url.Replace('-', '+').Replace('_', '/')
#   switch ($base64.Length % 4) {
#     2 { $base64 += '==' }
#     3 { $base64 += '=' }
#   }
#   return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
# }
# function local:ConvertFrom-JWT ([String]$Token) {
#   $parts = $Token -split '\.'
#   if ($parts.Length -ne 3) {
#     throw 'Invalid JWT token format'
#   }

#   $header = local:ConvertFrom-Base64Url -Base64Url $parts[0]
#   $payload = local:ConvertFrom-Base64Url -Base64Url $parts[1]
#   $signature = $parts[2]

#   return ([PSCustomObject]@{
#       Header    = $header
#       Payload   = $payload
#       Signature = $signature
#     })
# }
# function local:Invoke-OperatorValidation {
#   [CmdletBinding()]
#   param(
#     [Parameter(Mandatory = $true)]
#     [String]$Filter,

#     [Parameter(Mandatory = $true)]
#     [String]$Operator,

#     [Parameter(Mandatory = $true)]
#     [String]$Path
#   )
#   #########################################################
#   # Validate the filter and operator
#   #########################################################
#   $operatorValidationTable = .{
#     #######################################################
#     # <Version>/accounts
#     #######################################################
#     $operatorDictionary = [Dictionary[String, String[]]]::new()
#     $operatorDictionary['id'                      ] = @('eq', 'in', 'sw')
#     $operatorDictionary['identityId'              ] = @('eq', 'in', 'sw')
#     $operatorDictionary['name'                    ] = @('eq', 'in', 'sw')
#     $operatorDictionary['sourceId'                ] = @('eq', 'in', 'sw')
#     $operatorDictionary['entitlements'            ] = @('eq')
#     $operatorDictionary['identity.name'           ] = @('eq', 'in', 'sw')
#     $operatorDictionary['identity.identityState'  ] = @('eq', 'in')
#     $operatorDictionary['source.displayableName'  ] = @('eq', 'in')
#     $lookupTable['v3/accounts'                    ] = $operatorDictionary
#     $lookupTable['v2024/accounts'                 ] = $operatorDictionary
#     $lookupTable['beta/accounts'                  ] = $operatorDictionary
#     #######################################################
#     $lookupTable = [ImmutableDictionary]::CreateRange($operatorDictionary)

#     Write-Verbose "Lookup table keys: $($lookupTable.Get_Keys() -join ', ')"
#     return $lookupTable
#   }

#   try {
#     if (-not $operatorValidationTable.ContainsKey($Path)) {
#       Write-Warning "The command ""$Path"" was not validated"
#     }

#     if (-not $operatorValidationTable[$Path]) {
#       throw "The argument ""$Filter"" is not supported for command ""$Path"""
#     }

#     if (-not $Operator) {
#       return $operatorValidationTable[$Path][$Filter]
#     }

#     if ($Operator -notin $operatorValidationTable[$Path][$Filter]) {
#       throw "The argument ""$Filter"" only supports """ +
#             ($operatorValidationTable[$Path][$Filter] -join ',') +
#       """ operators for command ""$Path"""
#     }
#   } catch {
#     throw $_
#   }
# }
# ###########################################################
# # Classes
# ###########################################################
# class ApiAccount {
# }
# class OperatorValidator : IArgumentCompleter {

#   [IEnumerable[CompletionResult]] CompleteArgument(
#     [String] $commandName,
#     [String] $paramterName,
#     [String] $workToComplete,
#     [CommandAst] $commandAst,
#     [IDictionary] $fakeBoundParameters) {

#     $operatorList = (Invoke-OperatorValidation -Filter $fakeBoundParameters['Filter'] -CommandName $commandName)

#     $resultList = [List[CompletionResult]]::new()

#     $operatorList | ForEach-Object { $resultList.Add([OperatorValidator]::new()) }

#     return $resultList
#   }
# }
# class OperatorArgumentCompleter : ArgumentCompleter, IArgumentCompleterFactory {
#   OperatorValidationFactory() {}
#   [IArgumentCompleter] Create() { return [OperatorValidator]::new() }
# }

#endregion
###########################################################
#
# Grok module
#
###########################################################
#region - Connect-GrokApi.ps1
# function Connect-GrokApi {
#   CmdletBinding(DefaultParameterSetName = 'Credentials',
#     # SupportsShouldProcess = $True,
#     ConfirmImpact = 'Low',
#     HelpUri = 'This cmdlet connects to the Grok API using an API key or saved credentials.')]
#   [Alias('Login-GrokApi')]
#   param (
#     [Parameter(Mandatory = $False,
#       ParameterSetName = 'Credentials',
#       Position = 0,
#       ValueFromPipeline = $True,
#       ValueFromPipelineByPropertyName = $True,
#       HelpMessage = 'Enter the credentials to connect to the Grok API')]
#     [PSCredential]$Credentials = [PSCredential]::Empty,

#     [Parameter(Mandatory = $False,
#       ParameterSetName = 'API_Key',
#       Position = 0,
#       ValueFromPipeline = $True,
#       ValueFromPipelineByPropertyName = $True,
#       HelpMessage = 'Enter the API key to connect to the Grok API')]
#     [ValidateNotNull()]
#     [SecureString]
#     $ApiKey = $null,

#     [Parameter(Mandatory = $False,
#       Position = 30,
#       HelpMessage = 'Variable to store the response headers.')]
#     [String]$ResponseHeadersVariable,

#     [Parameter(Mandatory = $False, HelpMessage = 'Override existing credentials file.')]
#     [Switch]$Force = $False
#   )
#   begin {
#   }
#   process {
#     #######################################################
#     #region - Set Request Parameters
#     #######################################################
#     try {

#       $body = @{
#         messages    = @(
#           @{
#             role    = 'system'
#             content = 'You are a test assistant.'
#           },
#           @{
#             role    = 'user'
#             content = 'Testing. Just say hi and hello world and nothing else.'
#           }
#         )
#         model       = 'grok-3-latest'
#         stream      = $False
#         temperature = 0.000000000000000000000000000000000000000000001 # Smallest 32-bit float I could find
#       } | ConvertTo-Json -Depth 4 -Compress

#       $body = $body -replace '1E-45', '0.000000000000000000000000000000000000000000001'

#       $uri = "$($Global:Grok.BaseUrl)/chat/completions"

#       $splats = @{
#         Uri                = $uri
#         Method             = [System.Net.WebRequestMethods+Http]::Post
#         Headers            = Get-DefaultHeaders -Force:$Force
#         Body               = $body
#         SkipHttpErrorCheck = $True
#         StatusCodeVariable = 'StatusCode'
#       }

#       if ($ResponseHeadersVariable) {
#         $ResponseHeaders = @{}
#         $splats.ResponseHeaders = $ResponseHeaders
#       }
#     } catch {

#       $PSCmdlet.ThrowTerminatingError(
#         [System.Management.Automation.ErrorRecord]::new(
#           [System.Exception]::new('No IP was obtained from invoker.'), # System.Exception exception
#           'NoIPObtained', # string errorId
#           [System.Management.Automation.ErrorCategory]::InvalidOperation, # System.Management.Automation.ErrorCategory errorCategory
#           $null # System.Object targetObject
#         )
#       )

#       throw $_
#     }
#     #endregion
#     #######################################################
#     #region - Invoke-ProxyRestMethod
#     #######################################################
#     try {

#       # TODO: This can go into the Invoke-ProxyRestMethod function
#       Write-Verbose "---> Invoke-ProxyRestMethod $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#       Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats
#       $response = Invoke-RestMethod @splats
#       $Global:GrokResponseHeaders = $ResponseHeaders
#       Write-Verbose "<--- Invoke-ProxyRestMethod $($response)"
#       Write-GrokLog -Operation 'Response' -InputObject $response
#     } catch {
#       $exception = [System.Exception]::new('BAD')
#       $errorId = 'BAD'
#       $errorCategory = 'NotSpecified'
#       $errorRecord = [System.Management.Automation.ErrorRecord]::new(
#         $exception, $errorId, $errorCategory, $null
#       )
#       $PSCmdlet.WriteError($errorRecord)
#       Write-Error $_
#     }
#     #endregion
#     #######################################################
#     #region - Create Response Object
#     #######################################################
#     $response = [PSCustomObject]@{
#       Type     = 'https://docs.x.ai/docs/api-reference#chat-completions'
#       Title    = "Reason code: $([System.Net.HttpStatusCode]$StatusCode)"
#       Status   = $StatusCode
#       Detail   = $response
#       Instance = $uri
#     }

#     if ($ResponseHeadersVariable) {
#       Set-Variable -Name $ResponseHeadersVariable -Value $ResponseHeaders -Scope 'Global'
#     }

#     if ($StatusCode -ne 200) {
#       $exception = [System.Exception]::new($response.Detail.Error)
#       $errorId = $response.Detail.Code
#       $errorCategory = [System.Management.Automation.ErrorCategory]::AuthenticationError
#       $errorRecord = [System.Management.Automation.ErrorRecord]::new(
#         $exception, $errorId, $errorCategory, $response
#       )
#       $PSCmdlet.ThrowTerminatingError($errorRecord)
#     }

#     return $response
#     #endregion
#   }
#   end { }
# }
#endregion
###########################################################
#region - Configuration.ps1
# TODO:
# $ExecutionContext.SessionState isn't actually used yet
###########################################################
<#
  Initializes the Grok module configuration and application data
  In this function we ustialize the $ExecutionContext.SessionState
    Explanation:
      PowerShell session
      A session is the environment in which a PowerShell process runs.
      This environment allows to execute commands and add items to it.
      Container for items
      A session is a logical container for different kinds items
    More on PowerShell Session can be found here:
      https://www.renenyffenegger.ch/notes/Windows/PowerShell/session/index
#>
###########################################################
# function Initialize-GrokConfiguration {
#   [CmdletBinding()]
#   param(
#   )

#   #########################################################
#   #region - Set the Api context and cache
#   #########################################################
#   Write-Verbose '---> Initializing module application data'
#   # $Global:Grok = @{
#   $Global:Grok = [PSCustomObject]@{
#     BaseUrl         = 'https://api.x.ai/v1'
#     AppFolder       = "$($HOME)/Grok/"
#     CacheFolder     = "$($HOME)/Grok/cache"
#     LogFolder       = "$($HOME)/Grok/logs"
#     LogFile         = "$($HOME)/Grok/logs/Grok.jsonc"  # changed to JSON file
#     CredentialsFile = "$($HOME)/Grok/credentials.clixml"
#   }
#   $Global:Grok | Add-Member -MemberType 'ScriptMethod' -Name 'InitializeAppData' -Value {
#     write-host 'TODO: put the folder creation code here'
#   }
#   #endregion
#   #########################################################
#   #region - Module app data folder and log files setup
#   #########################################################
#   Write-Verbose "---> Creating folder data folders: $folder"
#   foreach ($folder in $Global:Grok.psobject.properties.value ) {
#     if ($folder -match 'Folder' -and -not (Test-Path -Path $folder)) {
#       Write-Verbose "---> Creating folder start: $folder"
#       New-Item -Path $folder -ItemType 'Directory' -Force | Out-Null
#       Write-Verbose "<--- Creating folder finish: $folder"
#     }
#   }
#   Write-Verbose '<--- Module application data folders created.'
#   #endregion
#   #########################################################
#   #region - Set the log file
#   #########################################################
#   if (-not (Test-Path -Path $Global:Grok.LogFile)) {
#     Write-Verbose "---> Creating log file: $($Global:Grok.LogFile)"
#     New-Item -Path $Global:Grok.LogFile -ItemType 'File' -Force | Out-Null
#     Write-Verbose '<--- Log file created'
#   }
#   #endregion
#   #########################################################
#   Write-Verbose '<--- Module application data initialized.'
# }

#endregion
###########################################################
#region - Log.ps1
# function Write-GrokLog {
#   param(
#     [String]$Operation,
#     [PSCustomObject]$InputObject
#   )
#   begin {
#     #######################################################
#     # - Check Log file size and archive if necessary
#     #######################################################
#     $logFile = $Global:Grok.LogFile
#     if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 2.4MB) {
#       Write-Verbose '---> Log file size exceeds 2.4MB, archiving...'
#       $archiveFile = "$($Global:Grok.LogFolder)/archive/$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').json"  # changed archive name
#       Move-Item $logFile $archiveFile -Force
#       Set-Content -Path $logFile -Value "{""message"":""Previous log moved to $archiveFile""}" -Force
#       Write-Verbose "<--- Log file archived to: $archiveFile"
#     }
#   }
#   process {
#     #######################################################
#     # Redact Sensitive Information
#     #######################################################
#     $copiedAuthHeader = $null
#     if ($InputObject?.Headers?.Authorization) {
#       $copiedAuthHeader = $InputObject.Headers.Authorization
#       $InputObject.Headers.Authorization = 'Bearer REDACTED'
#     }

#     if ($InputObject?.ResponseHeaders?.'Set-Cookie ') {
#       $InputObject.ResponseHeaders.'Set-Cookie ' = 'REDACTED'
#     }

#     [PSCustomObject]@{
#       Timestamp   = (Get-Date).ToString('o')
#       Operation   = $Operation
#       InputObject = $InputObject
#     } | ConvertTo-Json -Compress -Depth 10 | Out-File -FilePath $Global:Grok.LogFile -Append
#   }
#   clean {
#     if ($copiedAuthHeader) {
#       $InputObject.Headers.Authorization = $copiedAuthHeader
#     }
#   }
# }
#endregion
###########################################################
#region - Get-ApiKey.ps1
# function Get-GrokApiKey {
#   [CmdletBinding()]
#   param(
#     [Switch]$Force = [Switch]$False
#   )
#   BEGIN {
#     #######################################################
#     #region - Initialize Grok Configuration
#     #######################################################
#     if ($null -eq $Global:Grok) { Initialize-GrokConfiguration }
#     #endregion
#     #######################################################
#     #region - Use Saved Credentials
#     #######################################################
#     $XAI_API_KEY = $null
#     if ((Test-Path -Path $Global:Grok.CredentialsFile)) {
#       [SecureString]$XAI_API_KEY = Get-SavedCredentials
#     }
#     #endregion
#     #######################################################
#     #region - Set Api Credentials when not using cached credentials
#     #######################################################
#     if (-not $XAI_API_KEY -or $XAI_API_KEY.Length -eq 0) {
#       switch ($PSCmdlet.ParameterSetName) {
#         'API_Key' {
#           if (-not $ApiKey -or $ApiKey.Length -eq 0) {
#             $XAI_API_KEY = Read-Host -Prompt 'Enter your API key' -AsSecureString
#           }
#           $XAI_API_KEY = $ApiKey
#         }
#         'Credentials' {
#           if ($XAI_API_KEY -eq [PSCredential]::Empty) {
#             $XAI_API_KEY = Get-Credential -Message 'Enter API Key to connect to the Grok API, Username not in use'
#           }
#           $credits = $credits.Password
#         }
#         Default {}
#       }
#     }
#     #endregion
#     #######################################################
#     #region - Save Credentials
#     #######################################################
#     try {
#       Write-Verbose '---> Saving credentials to file'
#       if ($Force.IsPresent) {
#         Write-Verbose '---> Forcing credentials to be saved'
#         $credits | Export-Clixml -Path $Global:Grok.CredentialsFile -Force
#       } else {
#         $credits | Export-Clixml -Path $Global:Grok.CredentialsFile -NoClobber -ErrorVariable 'saveCredsClobber'
#       }
#       Write-Verbose "<--- Credentials saved to: $($Global:Grok.CredentialsFile)"
#     } catch {
#       if ($saveCredsClobber) {
#         Write-Warning 'Credentials file already exists, use -Force to overwrite'
#       } else {
#         throw $_
#       }
#     }
#     #endregion
#   }
#   PROCESS {

#     # Get the file path for the credentials
#     $credentialsFile = $Global:Grok.CredentialsFile

#     # Check if the credentials file exists
#     if (-not (Test-Path -Path $credentialsFile)) {
#       throw "Credentials file not found: $credentialsFile"
#     }

#     # Import the credentials from the file
#     $credentials = Import-Clixml -Path $credentialsFile |
#       ConvertFrom-SecureString -AsPlainText

#     # Return the API key
#     return $credentials

#   }
#   END { }
# }
# function Get-DefaultHeaders {
#   [CmdletBinding()]
#   param(
#     [Switch]$Force = [Switch]$False
#   )
#   BEGIN { }
#   PROCESS {
#     return @{
#       Authorization  = "Bearer $(Get-GrokApiKey -Force:$Force)"
#       'Content-Type' = 'application/json'
#     }
#   }
#   END { }
# }
# function Get-SavedCredentials {
#   [CmdletBinding()]
#   param(
#     [Parameter(Mandatory = $False)][Switch]$AsPlainText = [Switch]$False
#   )
#   BEGIN { }
#   PROCESS {
#     #######################################################
#     #region - Get the file path for the credentials
#     #######################################################
#     $credentialsFile = $Global:Grok.CredentialsFile
#     #######################################################
#     #region - Check if the credentials file exists
#     #######################################################
#     if (-not (Test-Path -Path $credentialsFile)) {
#       Write-Verbose "---> Credentials file not found: $credentialsFile"
#       return $null
#     }
#     #######################################################
#     #region - Import the credentials from the file
#     #######################################################
#     Write-Verbose '---> Using saved credentials'
#     $credentials = Import-Clixml -Path $credentialsFile |
#       ConvertFrom-SecureString -AsPlainText:$AsPlainText
#     #######################################################
#     #region - Return the credentials
#     return $credentials
#     #######################################################
#   }
#   END { }
# }
#endregion
###########################################################
#region - Get-GrokConfiguration.ps1
# function Get-GrokConfiguration {
#   [CmdletBinding()]
#   param (
#   )
#   #########################################################
#   #region - Initialize Configuration
#   #########################################################
#   if (-not $Global:Grok) {
#     Initialize-GrokConfiguration
#   }
#   #endregion
#   #########################################################
#   #region - Return Configuration
#   #########################################################
#   return $Global:Grok
#   #endregion
# }
#endregion
###########################################################
#region - Get-GrokModels.ps1
# function Get-GrokModels {
#   [CmdletBinding()]
#   param (
#   )
#   #########################################################
#   #region - Initialize Configuration
#   #########################################################
#   $splats = @{
#     Uri     = "$($Global:Grok.BaseUrl)/models"
#     Method  = [System.Net.WebRequestMethods+Http]::Get
#     Headers = GetDefaultHeaders
#   }
#   #endregion
#   #########################################################
#   #region - Invoke REST Method
#   #########################################################
#   Write-Verbose "---> $($MyInvocation.MyCommand.Name) $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#   Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats
#   $response = Invoke-RestMethod @splats
#   Write-Verbose "<--- $($MyInvocation.MyCommand.Name) $($response)"
#   Write-GrokLog -Operation 'Response' -InputObject $response
#   return $response
#   #endregion
#   #########################################################
# }
# function Get-GrokModelById {
#   [CmdletBinding()]
#   param (
#     [Parameter(Mandatory = $true)]
#     [string]$Id
#   )
#   #########################################################
#   #region - Initialize Configuration
#   #########################################################
#   $splats = @{
#     Uri     = "$($Global:Grok.BaseUrl)/models/$Id"
#     Method  = [System.Net.WebRequestMethods+Http]::Get
#     Headers = GetDefaultHeaders
#   }
#   #endregion
#   #########################################################
#   #region - Invoke REST Method
#   #########################################################
#   Write-Verbose "---> $($MyInvocation.MyCommand.Name) $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#   Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats
#   $response = Invoke-RestMethod @splats
#   Write-Verbose "<--- $($MyInvocation.MyCommand.Name) $($response)"
#   Write-GrokLog -Operation 'Response' -InputObject $response
#   return $response
#   #endregion
#   #########################################################
# }

#endregion
###########################################################
#region - Invoke-GrokMessage.ps1
# function Invoke-GrokMessage {
#   [CmdletBinding()]
#   param (
#     [Parameter(Mandatory = $true)]
#     [ValidateNotNullOrEmpty()]
#     [array]$Messages,

#     [Parameter(Mandatory = $true)]
#     [ValidateNotNullOrEmpty()]
#     [string]$Model,

#     [Parameter(Mandatory = $true)]
#     [ValidateRange(1, [int]::MaxValue)]
#     [int]$MaxTokens,

#     [Parameter(Mandatory = $false)]
#     [AllowNull()]
#     $System,

#     [Parameter(Mandatory = $false)]
#     [ValidateCount(0, 4)]
#     [string[]]$StopSequences,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(0, 2)]
#     [double]$Temperature = 1,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(0, 1)]
#     [double]$TopP = 1,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(1, [int]::MaxValue)]
#     [int]$TopK,

#     [Parameter(Mandatory = $false)]
#     [object]$Metadata,

#     [Parameter(Mandatory = $false)]
#     [object]$ToolChoice,

#     [Parameter(Mandatory = $false)]
#     [ValidateCount(0, 128)]
#     [array]$Tools,

#     [Parameter(Mandatory = $false)]
#     [switch]$Stream,

#     [Parameter(Mandatory = $false)]
#     [string]$ResponseHeadersVariable
#   )
#   begin { }
#   process {
#     #######################################################
#     #region - Initialize Configuration
#     #######################################################
#     if (-not $Global:Grok) {
#       Initialize-GrokConfiguration
#     }
#     #endregion
#     #######################################################
#     #region - Prepare Request
#     #######################################################
#     $body = @{
#       messages   = $Messages
#       model      = $Model
#       max_tokens = $MaxTokens
#     }

#     if ($PSBoundParameters.ContainsKey('System')) {
#       $body.system = $System
#     }
#     if ($PSBoundParameters.ContainsKey('StopSequences')) {
#       $body.stop_sequences = $StopSequences
#     }
#     if ($PSBoundParameters.ContainsKey('Temperature')) {
#       $body.temperature = $Temperature
#     }
#     if ($PSBoundParameters.ContainsKey('TopP')) {
#       $body.top_p = $TopP
#     }
#     if ($PSBoundParameters.ContainsKey('TopK')) {
#       $body.top_k = $TopK
#     }
#     if ($PSBoundParameters.ContainsKey('Metadata')) {
#       $body.metadata = $Metadata
#     }
#     if ($PSBoundParameters.ContainsKey('ToolChoice')) {
#       $body.tool_choice = $ToolChoice
#     }
#     if ($PSBoundParameters.ContainsKey('Tools')) {
#       $body.tools = $Tools
#     }
#     if ($Stream) {
#       $body.stream = $true
#     }

#     $bodyJson = $body | ConvertTo-Json -Depth 10 -Compress

#     $splats = @{
#       Uri                = "$($Global:Grok.BaseUrl)/messages"
#       Method             = [System.Net.WebRequestMethods+Http]::Post
#       Headers            = GetDefaultHeaders
#       Body               = $bodyJson
#       SkipHttpErrorCheck = $True
#       StatusCodeVariable = 'StatusCode'
#     }

#     if ($ResponseHeadersVariable) {
#       $ResponseHeaders = @{}
#       $splats.ResponseHeaders = $ResponseHeaders
#     }
#     #endregion
#     #######################################################
#     #region - Invoke-GrokMessage
#     #######################################################
#     Write-Verbose "---> $($MyInvocation.MyCommand.Name) $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#     Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats

#     $response = Invoke-RestMethod @splats

#     Write-Verbose "<--- $($MyInvocation.MyCommand.Name) $($response)"
#     Write-GrokLog -Operation 'Response' -InputObject $response
#     #endregion
#     #######################################################
#     #region - Handle Response
#     #######################################################
#     if ($ResponseHeadersVariable) {
#       Set-Variable -Name $ResponseHeadersVariable -Value $ResponseHeaders -Scope 'Global'
#     }
#     try {
#       if ($StatusCode -ne 200) {
#         $exception = [System.Exception]::new($response.Error)
#         $errorId = $response.Code
#         $errorCategory = [System.Management.Automation.ErrorCategory]::NotSpecified
#         $errorRecord = [System.Management.Automation.ErrorRecord]::new(
#           $exception, $errorId, $errorCategory, $response
#         )
#         $PSCmdlet.ThrowTerminatingError($errorRecord)
#       }
#     } catch {
#       throw $_
#     }
#     return $response
#     #endregion
#   }
# }

#endregion
###########################################################
#region - Invoke-GrokChat.ps1
# function Invoke-GrokChat {
#   [CmdletBinding()]
#   param (
#     [Parameter(Mandatory = $true)]
#     [ValidateNotNullOrEmpty()]
#     [array]$Messages,

#     [Parameter(Mandatory = $true)]
#     [ValidateNotNullOrEmpty()]
#     [string]$Model,

#     [Parameter(Mandatory = $false)]
#     [int]$MaxCompletionTokens,

#     [Parameter(Mandatory = $false)]
#     [int]$MaxTokens,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(1, [int]::MaxValue)]
#     [int]$N = 1,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(0, 2)]
#     [double]$Temperature = 1,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(0, 1)]
#     [double]$TopP = 1,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(-2, 2)]
#     [double]$FrequencyPenalty = 0,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(-2, 2)]
#     [double]$PresencePenalty = 0,

#     [Parameter(Mandatory = $false)]
#     [ValidateCount(0, 4)]
#     [string[]]$Stop,

#     [Parameter(Mandatory = $false)]
#     [switch]$Stream,

#     [Parameter(Mandatory = $false)]
#     [object]$StreamOptions,

#     [Parameter(Mandatory = $false)]
#     [switch]$Deferred,

#     [Parameter(Mandatory = $false)]
#     [bool]$ParallelToolCalls = $true,

#     [Parameter(Mandatory = $false)]
#     [object]$ToolChoice,

#     [Parameter(Mandatory = $false)]
#     [ValidateCount(0, 128)]
#     [array]$Tools,

#     [Parameter(Mandatory = $false)]
#     [object]$ResponseFormat,

#     [Parameter(Mandatory = $false)]
#     [ValidateSet('low', 'high', 'medium')]
#     [string]$ReasoningEffort = 'low',

#     [Parameter(Mandatory = $false)]
#     [int]$Seed,

#     [Parameter(Mandatory = $false)]
#     [string]$User,

#     [Parameter(Mandatory = $false)]
#     [object]$LogitBias,

#     [Parameter(Mandatory = $false)]
#     [switch]$Logprobs,

#     [Parameter(Mandatory = $false)]
#     [ValidateRange(0, 8)]
#     [int]$TopLogprobs,

#     [Parameter(Mandatory = $false)]
#     [object]$SearchParameters,

#     [Parameter(Mandatory = $false)]
#     [object]$WebSearchOptions,

#     [Parameter(Mandatory = $false)]
#     [string]$ResponseHeadersVariable
#   )
#   begin { }
#   process {
#     #######################################################
#     #region - Initialize Configuration
#     #######################################################
#     if (-not $Global:Grok) {
#       Initialize-GrokConfiguration
#     }
#     #endregion
#     #######################################################
#     #region - Prepare Request
#     #######################################################
#     $body = @{
#       messages = $Messages
#       model    = $Model
#     }

#     if ($PSBoundParameters.ContainsKey('MaxCompletionTokens')) {
#       $body.max_completion_tokens = $MaxCompletionTokens
#     }
#     if ($PSBoundParameters.ContainsKey('MaxTokens')) {
#       $body.max_tokens = $MaxTokens
#     }
#     if ($PSBoundParameters.ContainsKey('N')) {
#       $body.n = $N
#     }
#     if ($PSBoundParameters.ContainsKey('Temperature')) {
#       $body.temperature = $Temperature
#     }
#     if ($PSBoundParameters.ContainsKey('TopP')) {
#       $body.top_p = $TopP
#     }
#     if ($PSBoundParameters.ContainsKey('FrequencyPenalty')) {
#       $body.frequency_penalty = $FrequencyPenalty
#     }
#     if ($PSBoundParameters.ContainsKey('PresencePenalty')) {
#       $body.presence_penalty = $PresencePenalty
#     }
#     if ($PSBoundParameters.ContainsKey('Stop')) {
#       $body.stop = $Stop
#     }
#     if ($Stream) {
#       $body.stream = $true
#     }
#     if ($PSBoundParameters.ContainsKey('StreamOptions')) {
#       $body.stream_options = $StreamOptions
#     }
#     if ($Deferred) {
#       $body.deferred = $true
#     }
#     if ($PSBoundParameters.ContainsKey('ParallelToolCalls')) {
#       $body.parallel_tool_calls = $ParallelToolCalls
#     }
#     if ($PSBoundParameters.ContainsKey('ToolChoice')) {
#       $body.tool_choice = $ToolChoice
#     }
#     if ($PSBoundParameters.ContainsKey('Tools')) {
#       $body.tools = $Tools
#     }
#     if ($PSBoundParameters.ContainsKey('ResponseFormat')) {
#       $body.response_format = $ResponseFormat
#     }
#     if ($PSBoundParameters.ContainsKey('ReasoningEffort')) {
#       $body.reasoning_effort = $ReasoningEffort
#     }
#     if ($PSBoundParameters.ContainsKey('Seed')) {
#       $body.seed = $Seed
#     }
#     if ($PSBoundParameters.ContainsKey('User')) {
#       $body.user = $User
#     }
#     if ($PSBoundParameters.ContainsKey('LogitBias')) {
#       $body.logit_bias = $LogitBias
#     }
#     if ($Logprobs) {
#       $body.logprobs = $true
#     }
#     if ($PSBoundParameters.ContainsKey('TopLogprobs')) {
#       $body.top_logprobs = $TopLogprobs
#     }
#     if ($PSBoundParameters.ContainsKey('SearchParameters')) {
#       $body.search_parameters = $SearchParameters
#     }
#     if ($PSBoundParameters.ContainsKey('WebSearchOptions')) {
#       $body.web_search_options = $WebSearchOptions
#     }

#     $bodyJson = $body | ConvertTo-Json -Depth 10 -Compress

#     $splats = @{
#       Uri                = "$($Global:Grok.BaseUrl)/chat/completions"
#       Method             = [System.Net.WebRequestMethods+Http]::Post
#       Headers            = GetDefaultHeaders
#       Body               = $bodyJson
#       SkipHttpErrorCheck = $True
#       StatusCodeVariable = 'StatusCode'
#     }

#     if ($ResponseHeadersVariable) {
#       $ResponseHeaders = @{}
#       $splats.ResponseHeaders = $ResponseHeaders
#     }
#     #endregion
#     #######################################################
#     #region - Invoke-GrokChat
#     #######################################################
#     Write-Verbose "---> $($MyInvocation.MyCommand.Name) $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#     Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats

#     $response = Invoke-RestMethod @splats

#     Write-Verbose "<--- $($MyInvocation.MyCommand.Name) $($response)"
#     Write-GrokLog -Operation 'Response' -InputObject $response
#     #endregion
#     #######################################################
#     #region - Handle Response
#     #######################################################
#     if ($ResponseHeadersVariable) {
#       Set-Variable -Name $ResponseHeadersVariable -Value $ResponseHeaders -Scope 'Global'
#     }
#     try {
#       if ($StatusCode -ne 200) {
#         $exception = [System.Exception]::new($response.Error)
#         $errorId = $response.Code
#         $errorCategory = [System.Management.Automation.ErrorCategory]::NotSpecified
#         $errorRecord = [System.Management.Automation.ErrorRecord]::new(
#           $exception, $errorId, $errorCategory, $response
#         )
#         $PSCmdlet.ThrowTerminatingError($errorRecord)
#       }
#     } catch {
#       throw $_
#     }
#     return $response
#     #endregion
#   }
# }

#endregion
###########################################################
#region - Invoke-GrokImageGeneration.ps1
# <#
# .SYNOPSIS
#    List image generation models
# .DESCRIPTION
#    /v1/image-generation-models

#    List all image generation models available to the authenticating API key with full information. Additional information compared to /v1/models includes modalities, pricing, fingerprint and alias(es).
# .EXAMPLE
#    Get-GrokImageGenerationModels
# .OUTPUTS
#     Array of available image generation models.

#     Alias ID(s) of the model that user can use in a request's model field.

#     Model creation time in Unix timestamp.

#     Fingerprint of the xAI system configuration hosting the model.

#     Model ID.

#     The input modalities supported by the model.

#     "model"

#     The output modalities supported by the model.

#     Owner of the model.

#     Version of the model.
# #>
# function Get-GrokImageGenerationModels {
#   [CmdletBinding()]
#   param (
#   )
#   #########################################################
#   #region - Initialize Configuration
#   #########################################################
#   $splats = @{
#     Uri     = "$($Global:Grok.BaseUrl)/image-generation-models"
#     Method  = [System.Net.WebRequestMethods+Http]::Get
#     Headers = GetDefaultHeaders
#   }
#   #endregion
#   #########################################################
#   #region - Invoke REST Method
#   #########################################################
#   Write-Verbose "---> $($MyInvocation.MyCommand.Name) $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#   Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats
#   $response = Invoke-RestMethod @splats
#   Write-Verbose "<--- $($MyInvocation.MyCommand.Name) $($response)"
#   Write-GrokLog -Operation 'Response' -InputObject $response
#   return $response.models
#   #endregion
#   #########################################################
# }
# <#
# .SYNOPSIS
#    Get image generation model by ID
# .DESCRIPTION
#    /v1/image-generation-models/{model_id}

#    Get full information about an image generation model with its model_id.
# .EXAMPLE
#    Get-GrokImageGenerationModelById -Id 'model_id'
# .PARAMETER Id
#    ID of the model to get.
# .OUTPUTS
#     Alias ID(s) of the model that user can use in a request's model field.

#     Model ID.
# #>
# function Get-GrokImageGenerationModelById {
#   [CmdletBinding()]
#   param (
#     [Parameter(Mandatory = $true)]
#     [string]$Id
#   )
#   #########################################################
#   #region - Initialize Configuration
#   #########################################################
#   $splats = @{
#     Uri     = "$($Global:Grok.BaseUrl)/image-generation-models/$Id"
#     Method  = [System.Net.WebRequestMethods+Http]::Get
#     Headers = GetDefaultHeaders
#   }
#   #endregion
#   #########################################################
#   #region - Invoke REST Method
#   #########################################################
#   Write-Verbose "---> $($MyInvocation.MyCommand.Name) $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#   Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats
#   $response = Invoke-RestMethod @splats
#   Write-Verbose "<--- $($MyInvocation.MyCommand.Name) $($response)"
#   Write-GrokLog -Operation 'Response' -InputObject $response
#   return $response.model
#   #endregion
#   #########################################################
# }

#endregion
###########################################################
#region - Get-GrokImageGenerationModels.ps1
# function Invoke-GrokImageGeneration {
#   [CmdletBinding(DefaultParameterSetName = 'PromptInput')]
#   param (
#     [Parameter(Mandatory = $true, ParameterSetName = 'PromptInput')]
#     [string]$Prompt,

#     [Parameter(Mandatory = $true, ParameterSetName = 'FileInput')]
#     [string]$PromptFile,

#     [Parameter(Mandatory = $false)]
#     [string]$Model = 'grok-2-image-latest',

#     [Parameter(Mandatory = $false)]
#     [int]$NumberOfImages = 1,

#     [Parameter(Mandatory = $false)]
#     [ValidateSet('url', 'b64_json')]
#     [string]$ResponseFormat = 'b64_json',

#     [Parameter(Mandatory = $false)]
#     [string]$User,

#     [Parameter(Mandatory = $false)]
#     [string]$ResponseHeadersVariable
#   )
#   begin { }
#   process {
#     #######################################################
#     #region - Initialize Configuration
#     #######################################################
#     if (-not $Global:Grok) {
#       Initialize-GrokConfiguration
#     }
#     #endregion
#     #######################################################
#     #region - Prepare Request
#     #######################################################
#     if ($PSCmdlet.ParameterSetName -eq 'FileInput') {
#       if (-not (Test-Path -Path $PromptFile)) {
#         throw "File '$PromptFile' does not exist."
#       }
#       $Prompt = Get-Content -Path $PromptFile -Raw -ErrorAction Stop
#     }

#     $joinedPrompt = $Prompt -join "`n"
#     $encodedPrompt = [System.Web.HttpUtility]::HtmlEncode($joinedPrompt)
#     $body = @{
#       prompt          = $encodedPrompt
#       model           = $Model
#       n               = $NumberOfImages
#       response_format = $ResponseFormat
#       # UserId          = $UserId
#     } | ConvertTo-Json -Depth 4 -Compress

#     $splats = @{
#       Uri                = "$($Global:Grok.BaseUrl)/images/generations"
#       Method             = [System.Net.WebRequestMethods+Http]::Post
#       Headers            = GetDefaultHeaders
#       Body               = $body
#       SkipHttpErrorCheck = $True
#       StatusCodeVariable = 'StatusCode'
#     }

#     if ($ResponseHeadersVariable) {
#       $ResponseHeaders = @{}
#       $splats.ResponseHeaders = $ResponseHeaders
#     }
#     #endregion
#     #######################################################
#     #region - Invoke-GrokImageGeneration
#     #######################################################
#     Write-Verbose "---> $($MyInvocation.MyCommand.Name) $($splats.Get_Keys().ForEach({"-$($_) '$($splats[$_])'"}))"
#     Write-GrokLog -Operation 'Invoke-RestMethod' -InputObject $splats

#     $response = Invoke-RestMethod @splats

#     Write-Verbose "<--- $($MyInvocation.MyCommand.Name) $($response)"
#     Write-GrokLog -Operation 'Response' -InputObject $response
#     #endregion
#     #######################################################
#     #region - Handle Response
#     #######################################################
#     if ($ResponseHeadersVariable) {
#       Set-Variable -Name $ResponseHeadersVariable -Value $ResponseHeaders -Scope 'Global'
#     }
#     try {
#       if ($StatusCode -ne 200) {
#         $exception = [System.Exception]::new($response.Error)
#         $errorId = $response.Code
#         $errorCategory = [System.Management.Automation.ErrorCategory]::NotSpecified
#         $errorRecord = [System.Management.Automation.ErrorRecord]::new(
#           $exception, $errorId, $errorCategory, $response
#         )
#         $PSCmdlet.ThrowTerminatingError($errorRecord)
#       }
#     } catch {
#       throw $_
#     }
#     return $response
#     #endregion
#   }
# }
#endregion
###########################################################
#region - Base64Image.ps1
# <#
# # Suppose this is the JSON output
# $json = @"
# {
#     "image": "iVBORw0KGgoAAAANSUhEUgAAA..."
# }
# "@ | ConvertFrom-Json

# # Save the image
# Save-Base64ImageToFile -Base64String $json.image -OutputFilePath "$HOME\Downloads\image.png"

# #>
# function Save-Base64ImageToFile {
#   [CmdletBinding()]
#   param (
#     [Parameter(Mandatory)]
#     [string]$Base64String,

#     [Parameter()]
#     [string]$OutputFilePath = "$($Global:Grok.CacheFolder)/grok-$((New-Guid).Guid)-$(Get-Date -Format 'yyyyMMdd-HHmmss')).png"
#   )

#   try {
#     # Remove any data URI prefix if present (e.g., "data:image/png;base64,")
#     if ($Base64String -match '^data:image\/[a-zA-Z]+;base64,') {
#       $Base64String = $Base64String -replace '^data:image\/[a-zA-Z]+;base64,', ''
#     }

#     # Convert from Base64 to byte array
#     $bytes = [Convert]::FromBase64String($Base64String)

#     # Save to file
#     [System.IO.File]::WriteAllBytes($OutputFilePath, $bytes)

#     Write-Host "File saved to $OutputFilePath"
#   } catch {
#     Write-Error "Failed to save image: $_"
#   }
# }

# <#
# # Just extract image data
# $images = Get-LastImageGenerationRequest -LogFile "$HOME\logs\imagegen.log"

# # Save recovered base64 images to files
# Get-LastImageGenerationRequest -LogFile "$HOME\logs\imagegen.log" -Save

# # Save to a specific directory
# Get-LastImageGenerationRequest -LogFile "$HOME\logs\imagegen.log" -Save -OutputPath "$HOME\Pictures\Recovered"


# #>
# function Get-LastImageGenerationRequest {
#   [CmdletBinding()]
#   param (
#     [Parameter()]
#     [switch]$Save,

#     [Parameter()]
#     [string]$LogFile = (Get-GrokConfiguration).LogFile,

#     [Parameter()]
#     [string]$OutputDirectory = "$HOME/Downloads"
#   )

#   begin {
#     if (-not (Test-Path $LogFile)) {
#       throw "Log file not found at '$LogFile'"
#     }
#   }

#   process {
#     # Read all lines and reverse the array using standard array reversal
#     $lines = Get-Content $LogFile
#     $reversedLines = @($lines)[-1.. - ($lines.Count)]

#     # Search from bottom up
#     foreach ($line in $reversedLines) {
#       if ($line -match '"b64_json"') {
#         try {
#           $json = $line | ConvertFrom-Json
#           $images = $json.InputObject.data

#           if ($Save) {
#             foreach ($img in $images) {
#               Save-Base64ImageToFile -Base64String $img.b64_json
#             }
#           }

#           return $images
#         } catch {
#           Write-Warning "Failed to parse JSON or save image: $_"
#           return $null
#         }
#       }
#     }

#     Write-Warning 'No base64 image generation request found in log.'
#     return $null
#   }
# }
#endregion
###########################################################
#region - The way the GROK PSM1 mod imports the functions
# ###########################################################
# #region - Import private scripts
# ###########################################################
# Get-ChildItem -Path "$PSScriptRoot\scripts\private" -File -Filter '*.ps1' -Recurse |
#   ForEach-Object { . $_.FullName }
# #endregion
# ###########################################################
# #region - Import public scripts
# ###########################################################
# Get-ChildItem -Path "$PSScriptRoot\scripts\public" -File -Filter '*.ps1' -Recurse |
#   ForEach-Object { . $_.FullName }
# #endregion
# ###########################################################
# #region - Initialize Configuration
# ###########################################################
# Initialize-GrokConfiguration
# #endregion
#endregion
###########################################################
#
# OKTA
#
###########################################################
#region - Okta rate limiting and Pagination
# ###########################################################
# # Get Okta Users with Pagination
# ###########################################################
# $oktaEnv = 'jvd-d01'
# $baseUrl = "domain-$($oktaEnv)-admin.okta.com"
# $api = 'api/v1/users'

# $secureString = Get-Credentials -Message "Okta API Token ($oktaEnv)" -UserName 'SSWS API Token'
# $headers = @{
#   Authorization = "SSWS $($secureString.GetNetworkCredential().Password)"
# }

# $splats = @{
#   Uri                     = "https://$baseUrl/api/v1/org"
#   Method                  = 'GET'
#   Headers                 = $headers
#   StatusCodeVariable      = 'S'
#   ResponseHeadersVariable = 'H'
#   ErrorVariable           = 'E'
#   OutVariable             = 'T'
# }

# try {
#   # Test Authentication
#   Invoke-RestMethod @splats | Out-Null
#   $splats.Uri = "https://$baseUrl/$($api)"
#   $sessionCache = @()

#   while ($splats.Uri) {

#     # Make the API call
#     $response = Invoke-RestMethod @splats

#     # Add the response to the cache
#     $sessionCache += $response

#     # Check for pagination
#     $splats.Uri = $h.link.Where({ $_ -like '*rel="next"*' }) -replace '^<(.*?)>.*$', '$1'

#     # Add 1 Second after the rate limit reset time, when the rate limit is reached
#     $rateLimit = $h.'x-rate-limit-limit'[0]
#     $rateLimitRemaining = $h.'x-rate-limit-remaining'[0]
#     $rateLimitReset = [DateTimeOffset]::FromUnixTimeSeconds([int]$h.'x-rate-limit-reset'[0])
#     if ($rateLimitRemaining -eq 0) {
#       Write-Verbose 'Rate limit reached. Waiting for reset...'
#       $rateLimitRemaining = $rateLimit
#       $waitTime = [int]($rateLimitReset - (Get-Date)).TotalSeconds + 1
#       Start-Sleep -Seconds $waitTime
#     }
#     [PSCustomObject]@{
#       RateLimit          = $rateLimit
#       RateLimitRemaining = $rateLimitRemaining
#       RateLimitReset     = $rateLimitReset.LocalDateTime.ToLongTimeString()
#       CacheCount         = $sessionCache.Count
#     }
#   }
# } catch {
#   throw $e
# }
#endregion
###########################################################
