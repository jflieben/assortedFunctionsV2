Add-Type -Path "C:\Users\jos\Desktop\net35\Microsoft.Exchange.WebServices.dll"

$Service = [Microsoft.Exchange.WebServices.Data.ExchangeService]::new()
$Service.Credentials = [System.Net.NetworkCredential]::new("admin@onedrivemapper.onmicrosoft.com" , "yourpassword")
$Service.Url = "https://outlook.office365.com/EWS/Exchange.asmx"

$maxDaysIntoTheFuture = 365

function Remove-ObsoleteCalendarItems{
    Param(
        $primaryEmailAddress #eg: admin@onedrivemapper.onmicrosoft.com
    )

    $folderid= new-object Microsoft.Exchange.WebServices.Data.FolderId([Microsoft.Exchange.WebServices.Data.WellKnownFolderName]::Calendar,$primaryEmailAddress)   
    $Calendar = [Microsoft.Exchange.WebServices.Data.Folder]::Bind($Service,$folderid)
    $Recurring = new-object Microsoft.Exchange.WebServices.Data.ExtendedPropertyDefinition([Microsoft.Exchange.WebServices.Data.DefaultExtendedPropertySet]::Appointment, 0x8223,[Microsoft.Exchange.WebServices.Data.MapiPropertyType]::Boolean); 
    $psPropset= new-object Microsoft.Exchange.WebServices.Data.PropertySet([Microsoft.Exchange.WebServices.Data.BasePropertySet]::FirstClassProperties)  
    $psPropset.Add($Recurring)
    $psPropset.RequestedBodyType = [Microsoft.Exchange.WebServices.Data.BodyType]::Text;

    #Define Date to Query 
    $currentDay = 0
    while($True){
        $StartDate = (Get-Date).AddDays($currentDay)
        $EndDate = $StartDate.AddDays(14)  
        $currentDay += 14

        if($currentDay -gt $maxDaysIntoTheFuture){
            break
        }

        $CalendarView = New-Object Microsoft.Exchange.WebServices.Data.CalendarView($StartDate,$EndDate,1000)    
        $fiItems = $service.FindAppointments($Calendar.Id,$CalendarView)
        if($fiItems.Items.Count -gt 0){
            $type = ("System.Collections.Generic.List"+'`'+"1") -as "Type"
            $type = $type.MakeGenericType("Microsoft.Exchange.WebServices.Data.Item" -as "Type")
            $ItemColl = [Activator]::CreateInstance($type)
            foreach($Item in $fiItems.Items){
                $ItemColl.Add($Item)
            } 
            [Void]$service.LoadPropertiesForItems($ItemColl,$psPropset)  
        }

        foreach($Item in $fiItems.Items){  
            if($Item.Organizer.Address -ne $primaryEmailAddress -and $Item.RequiredAttendees.Address -notcontains $primaryEmailAddress -and $Item.OptionalAttendees.Address -notcontains $primaryEmailAddress){
                $Item.RequiredAttendees.Clear() #this also works if no one is invited
                $Item.OptionalAttendees.Clear() #this also works if no one is invited
                $Item.Update([Microsoft.Exchange.WebServices.Data.ConflictResolutionMode]::AlwaysOverwrite,[Microsoft.Exchange.WebServices.Data.SendInvitationsOrCancellationsMode]::SendToNone)
                $Item.Delete([Microsoft.Exchange.WebServices.Data.DeleteMode]::MoveToDeletedItems)
                write-host "deleted item $($Item.Subject) without notifying recipients"
            }
        }
    }
}