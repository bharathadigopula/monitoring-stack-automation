//==============================================================================
// MONITORING STACK AUTOMATION VALIDATION
//==============================================================================

@Library('jenkins-pipeline-templates@v1.4.0') _

repositoryValidationPipeline(
    githubRepository: 'bharathadigopula/monitoring-stack-automation',
    shellSearchPath: 'scripts',
    validationScript: 'scripts/validate.sh',
    validationCommands: [
        'bash scripts/check-latest-versions.sh',
        'bash scripts/manage.sh dry-run',
        'test "$(wc -c < scripts/bootstrap.sh)" -le 4096'
    ],
    validateWorkflows: true
)