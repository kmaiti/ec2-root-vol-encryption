## Introduction
This script will encrypt root EBS volume of ec2 instance in aws. Multiple AWS api call are invoked using aws cli.
## Prerequisites 
- You need to configure profile using access key and secret key in machine where script will be executed. Default profile is added in PROFILE variable.
- EBS KMSID needs to be handy that will be used to encrypt root EBS
- jq binary is used to parse json data.

## How to run script
1. Download the script and save in file ec2_root_vol_encryption.sh
2. chmod +x ec2_root_vol_encryption.sh
3. Run like
./ec2_root_vol_encryption.sh  -i <INSTANCE ID>  -k <KMISID>


## Example on execution
```bash
ubuntu@ip-XX:~/scripts$ ./ec2_root_vol_encryption2.sh -i i-0aXXX -k eXXXXXXXXXXec
Instance i-0ac1091f0cfc20e0a is stopped...[OK]
Snapshot snap-049543d8a62ced7ca is completed...[OK]
Started i-0ac1091f0cfc20e0a...[OK]
Copying Snapshot snap-07dc1f1c255e1682f is completed...[OK]
New encrypted volume vol-09dea5bad2c997a38 is available now...[OK]
i-0ac1091f0cfc20e0a is stopped now.
Encrypted volume vol-09dea5bad2c997a38 is  to i-0ac1091f0cfc20e0a...[OK]
Starting i-0ac1091f0cfc20e0a ...
Instance i-0ac1091f0cfc20e0a is running now, operation is completed...[OK]
ubuntu@ip-XXX:~/scripts$
```
## Flow of the Execution
1. Collect volume ID attached to instance, Instance current state and AZ
2. Shutdown instance if running
3. Create snapshot of volume
4. Copy snapshot to create new snapshot in same AZ with encryption enabled.
5. Create volume from encrypted snapshot
6. Detach old root volume
7. Attach new encrypted Volume
8. Start instance if initially it was runnig
NOTE: Script dones't not cleanup snapshots and old volume. You need to manually cleanup. This was not added to avoid reverting the volume.
###### Contributors
- Kamal Maiti - kamal.maiti@gmail.com
