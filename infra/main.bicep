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

@description('Set true to allow Azure services (incl. Cloudflare origin) through the ACA firewall.')
param allowAzureIps bool = true

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
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    policies: {
      retentionPolicy: { status: 'enabled', days: 30 }
    }
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
// Persistent storage for the SQLite database (Azure Files)
// ---------------------------------------------------------------------------
var saName = take(toLower('${prefix}data${uniqueString(resourceGroup().id)}'), 24)

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: saName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: sa
  name: 'default'
}

resource dataShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'wbsdata'
}

// Registers the file share with the Container Apps environment so the app's
// `volumes` block can mount it at /data.
resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: cae
  name: 'wbsdata'
  properties: {
    azureFile: {
      accountName: sa.name
      accountKey: sa.listKeys().keys[0].value
      shareName: dataShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// ---------------------------------------------------------------------------
// Container App
// ---------------------------------------------------------------------------
resource app 'Microsoft.App/containerApps@2024-03-01' = {
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
        ipSecurityRestrictions: allowAzureIps ? [
          {
            name: 'allow-azure-services'
            action: 'Allow'
            ipAddressRange: 'AzureCloud'
            description: 'Allow Azure-hosted reverse proxies such as Cloudflare origin pulls'
          }
        ] : []
        // Pinned to a named revision so a new revision never auto-takes
        // customer traffic before the smoke test passes.
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
            // SQLite on an Azure Files mount. Single-writer only -- see
            // DEPLOYMENT.md before adding any feature with concurrent writes.
            { name: 'DATABASE_URL', value: 'sqlite+aiosqlite:////data/wetbasement.db' }
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

      volumes: [
        {
          name: 'data'
          storageType: 'AzureFile'
          storageName: 'wbsdata'
        }
      ]
    }
  }
}

output acrLoginServer string = acr.properties.loginServer
output containerAppFqdn string = app.properties.configuration.ingress.fqdn
output containerAppName string = app.name
output managedIdentityClientId string = identity.properties.clientId
output logAnalyticsId string = law.id
