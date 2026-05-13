using './main.bicep'

param location = 'centralus'
param prefix = 'corp'
param zones = ['1', '2', '3'] // set to [] for regions without Availability Zone support
param adminUsername = 'azureadmin'
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD')
