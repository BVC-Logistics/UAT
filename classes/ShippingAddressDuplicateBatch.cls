global class ShippingAddressDuplicateBatch 
implements Database.Batchable<SObject> {

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator(
            'SELECT Id FROM Account ORDER BY CreatedDate'
        );
    }

    global void execute(Database.BatchableContext bc, List<Account> scope) {

        for (Account acc : scope) {
            try {
                ShippingAddressDuplicateService.processCustomer(acc.Id);
            } catch (Exception e) {
                System.debug('Error processing Account: ' + acc.Id);
                System.debug(e.getMessage());
            }
        }
    }

    global void finish(Database.BatchableContext bc) {
        System.debug('Batch Processing Completed Successfully.');
    }
}