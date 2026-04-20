# ⚠️  Ne jamais versionner ce fichier (ajouter terraform.tfvars dans .gitignore)

subscription_id = "5eca8571-53e5-4e01-8013-33131d6861dd"
client_id       = "1a75b404-b014-45fc-8225-6af9cad04b3e"
client_secret   = "h3k8Q~cyomTIZypwYClrHjDC.TuFqvB67FR6JcDa"
tenant_id       = "e9e0b80a-44fb-41b0-a9b7-0dad33c26282"

# IP publique depuis laquelle tu accèdes au cluster (SSH + kubectl)
# Actuellement : IP du Cloud Shell Azure — remplace par ton IP perso si tu te connectes depuis ton poste
admin_ips = ["196.115.84.127", "196.92.1.224"]

ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCP7yA0jOsTE6qfuxWeMWBNrv6lJULrscZBc+s1SfSXEJYbZig8dBbzOayToM3bivJ9zZaj0nbN6fXrQ97Ouz4PE31WeyfX9b10Zn1x6kO0SRZckncMSZUNL9pCm//SAflhkhYop+m7D6TMyyaUdsgznK2K8fKmci+npVDpZ2OlNOXDsFX5FLVp7+YmkwtdV9+y8y9ytVh+W2JddLi0bixXKkoXBEEu7uMvRzKfHifvWInhcR4P2QBejSBt+YSR8viBd2yAqO4aacGa5ZYJin2QC/IQRqhzh0HhlqE70fcUW8ttZAexNM/R+w7GP/NxB4IRboLZaIzz8q9JxprjYg26eS+LZMaJCNkOr3Ju/wMIc1RcmciTCUJ/lQmc0bdksJuyvesbHcFCURdBauRexdrsGSLUhVGFA8zm+thmPpsqXt8OANGrwwMIIWWuTfp2vmhb9NUuIZjjq66KLqV6/5Bg1eK94gThXYSSxe22+ARNEtLediPaZSRw8vQBOoQ3uOuT0Bz9nASEAwZKz1PFzXfwDskVzhKLv7oqnAW7GuScGc7pcu2jfcOtQWARXzJkXkpt/xzd2cR5svmnrOki9lCgYitSXC1hazv1Wnx5gDKLy09IkG2W6bNG0mMOWMXpZJJzAHO+EPRQarXhKc+GrUehvV85nGDpDuSxUUWfEMguNw== samir@SandboxHost-639119361290448026"

location        = "westeurope"
master_vm_size  = "Standard_D2as_v6"
worker_vm_size  = "Standard_F1as_v7"
worker_count    = 2
os_disk_size_gb = 50
