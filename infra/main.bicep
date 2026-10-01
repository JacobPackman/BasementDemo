// Infrastructure for Wet Basement Services on Azure Container Apps.
//
// Design notes:
//  - ACR (not GHCR) so the Container App pulls images via managed identity.
//    No registry password exists anywhere, so nothing to rotate or leak.
//  - Log Analytics keeps container logs queryable (and is required for the env).
//  - minReplicas is a parameter on purpose. 0 = ~$0/mo with a cold start,
//    1 = ~$30/mo always warm. Start at 0 and measure real conversion impact.
//  - activeRevisionsMode: Multiple is what makes staged deploys and instant
//    rollback possible. Do not drop this to Single.

targetScope = 'resourceGroup'

@description('Azure region. Keep it near Seattle for latency: westus3 or westus2.')
param location string = 'westus3'

@description('Short prefix for all resource names.')
@maxLength(12)
param prefix string = 'wbs'

@description('0 = scale to zero (~$0/mo, 2-5s cold start). 1 = always warm (~$30/mo).')
@minValue(0)
@maxValue(3)
param minReplicas int = 0

@description('Max replicas. Keep at 1 while the database is SQLite on Azure Files -- concurrent writers over SMB can corrupt it. Raise only after migrating to Postgres.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 1

@description('CMS admin username for /admin.')
param adminUser string = 'admin'

@description('CMS admin password. Pass via --parameters adminPass=... or Key Vault reference.')
@secure()
param adminPass string

@description('Session signing key for the admin CMS.')
@secure()
param secretKey string

@description('Set FALSE on the first pass. The registry and environment must exist before the Container App, which needs an image that only exists after the first build. The bootstrap script deploys false, builds the image, then deploys true.')
param deployApp bool = true

var acrName = toLower('${prefix}acr${uniqueString(resourceGroup().id)}')
var envName = '${prefix}-env'
var appName = '${prefix}-web'
var lawName = '${prefix}-logs'
var identityName = '${prefix}-id'

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Registry -- Basic tier is ~$5/mo and includes 10 GiB.
// Admin user disabled deliberately: auth is AAD (push) + managed identity (pull).
//
// NOTE: do NOT set properties.policies.retentionPolicy on Basic. Azure rejects
// it with the misleading error "The SKU Basic is not supported" (SkuNotSupported)
// even on the GA API version -- it reads as a SKU problem but is really the
// retention policy. Untagged-manifest retention needs Standard or higher.
// Watch storage instead, or upgrade to Standard if images accumulate.
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

// ---------------------------------------------------------------------------
// User-assigned managed identity + AcrPull
// ---------------------------------------------------------------------------
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Container Apps Environment
// ---------------------------------------------------------------------------
resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

// ---------------------------------------------------------------------------
// NO Azure Files volume for the database. Deliberately removed.
//
// The app was mounted on an Azure Files (SMB) share with
// DATABASE_URL pointing at /data/wetbasement.db. It crashed in a loop:
//
//   sqlalchemy.exc.OperationalError: (sqlite3.OperationalError)
//     database is locked
//   [SQL: CREATE TABLE site_settings (...)]
//   ERROR:    Application startup failed. Exiting.   (exit code 3)
//
// SQLite relies on POSIX fcntl() byte-range locks. SMB does not implement them
// faithfully, so SQLite cannot even create its tables on an Azure Files mount.
// This is not a concurrency problem you can tune away with busy_timeout or
// journal_mode -- WAL is worse, since it also needs shared memory (mmap).
//
// Azure Container Apps only offers Azure Files for persistent volumes, so
// there is NO reliable way to run SQLite on a persistent ACA volume.
//
// Therefore: SQLite runs on the container's LOCAL disk (see DATABASE_URL
// below). It works, but it is EPHEMERAL -- every new revision starts with an
// empty database and re-seeds. Fine for a demo; for real persistence move to
// Azure Database for PostgreSQL Flexible Server (Burstable B1ms, ~$13/mo).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Container App
// ---------------------------------------------------------------------------
resource app 'Microsoft.App/containerApps@2024-03-01' = if (deployApp) {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      // Multiple = staged revisions + traffic splitting + instant rollback.
      activeRevisionsMode: 'Multiple'
      maxInactiveRevisions: 10

      ingress: {
        external: true
        targetPort: 8000
        allowInsecure: false
        // NOTE: ipSecurityRestrictions.ipAddressRange requires a real CIDR.
        // Service tags such as "AzureCloud" are rejected at preflight with
        // IpRestrictionsAddressEnteredInvalid. To lock this down to Cloudflare
        // later, list their published IPv4/IPv6 ranges explicitly.
        ipSecurityRestrictions: []
        // Initial state: one revision, so "latest gets everything" is correct
        // here. IMPORTANT: latestRevision:true means traffic FOLLOWS the newest
        // revision -- every new revision would immediately go live. Staging is
        // therefore enforced by the pipeline, which pins traffic back to the
        // previous revision after creating a new one. Do not assume this block
        // stages anything by itself.
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }

      // Pull via managed identity -- no registry credentials exist.
      // `identity` on the registry entry is the GA path; `identitySettings`
      // (lifecycle: All) is only a preview-API concept and is required when
      // the registry sits behind a private endpoint. Not needed here.
      registries: [
        {
          server: '${acrName}.azurecr.io'
          identity: identity.id
        }
      ]

      secrets: [
        { name: 'admin-pass', value: adminPass }
        { name: 'secret-key', value: secretKey }
      ]
    }

    template: {
      containers: [
        {
          name: 'web'
          image: '${acrName}.azurecr.io/${appName}:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'ADMIN_USER', value: adminUser }
            { name: 'ADMIN_PASS', secretRef: 'admin-pass' }
            { name: 'SECRET_KEY', secretRef: 'secret-key' }
            // Container-LOCAL path, deliberately NOT /data. SQLite cannot run
            // on an Azure Files (SMB) mount -- see the note above the Container
            // App. Trade-off: this disk is ephemeral, so the database is
            // recreated and re-seeded on every new revision. Acceptable for a
            // demo; use PostgreSQL for anything real.
            { name: 'DATABASE_URL', value: 'sqlite+aiosqlite:////app/wetbasement.db' }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/health', port: 8000 }
              initialDelaySeconds: 10
              periodSeconds: 30
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health', port: 8000 }
              initialDelaySeconds: 5
              periodSeconds: 10
              failureThreshold: 3
            }
          ]
        }
      ]

      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: { concurrentRequests: '50' }
            }
          }
        ]
      }
    }
  }
}

output acrLoginServer string = acr.properties.loginServer
// `app!` non-null assertion: the resource only exists when deployApp is true,
// which is exactly the branch this ternary takes.
output containerAppFqdn string = deployApp ? app!.properties.configuration.ingress.fqdn : ''
output containerAppName string = deployApp ? app!.name : appName
output managedIdentityClientId string = identity.properties.clientId
output logAnalyticsId string = law.id
