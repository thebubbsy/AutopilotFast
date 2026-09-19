<#
.SYNOPSIS
    Custom exception thrown when Autopilot hardware hash (OA3 blob) validation fails.
.DESCRIPTION
    Inherits from System.Exception. Provides structured diagnostic error codes, byte length
    metrics, and header tags for granular troubleshooting and test assertions.
#>
if (-not ('AutopilotHashParseException' -as [type])) {
    class AutopilotHashParseException : System.Exception {
        [string]$ErrorCode = 'GenericParseError'
        [int]$ActualLength = 0
        [int]$ExpectedLength = 0
        [byte]$HeaderByte = 0

        AutopilotHashParseException() : base("Autopilot hardware hash parsing failed: Invalid OA3 structure or bounds.") {}

        AutopilotHashParseException([string]$message) : base($message) {}

        AutopilotHashParseException([string]$message, [System.Exception]$innerException) : base($message, $innerException) {}

        AutopilotHashParseException([string]$message, [string]$errorCode) : base($message) {
            $this.ErrorCode = $errorCode
        }

        AutopilotHashParseException([string]$message, [string]$errorCode, [System.Exception]$innerException) : base($message, $innerException) {
            $this.ErrorCode = $errorCode
        }

        AutopilotHashParseException([string]$message, [string]$errorCode, [int]$actualLength, [int]$expectedLength) : base($message) {
            $this.ErrorCode = $errorCode
            $this.ActualLength = $actualLength
            $this.ExpectedLength = $expectedLength
        }

        AutopilotHashParseException([string]$message, [string]$errorCode, [int]$actualLength, [int]$expectedLength, [byte]$headerByte) : base($message) {
            $this.ErrorCode = $errorCode
            $this.ActualLength = $actualLength
            $this.ExpectedLength = $expectedLength
            $this.HeaderByte = $headerByte
        }

        AutopilotHashParseException([string]$message, [string]$errorCode, [int]$actualLength, [int]$expectedLength, [byte]$headerByte, [System.Exception]$innerException) : base($message, $innerException) {
            $this.ErrorCode = $errorCode
            $this.ActualLength = $actualLength
            $this.ExpectedLength = $expectedLength
            $this.HeaderByte = $headerByte
        }
    }
}
