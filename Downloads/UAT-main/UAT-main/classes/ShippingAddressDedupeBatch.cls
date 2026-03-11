global class ShippingAddressDedupeBatch
implements Database.Batchable<SObject> {

    private static final Pattern PAN_PATTERN =
        Pattern.compile('^[A-Z]{5}[0-9]{4}[A-Z]{1}$');

    // Class level map to track failures across all batches
    global Map<Id, String> failedRecords = new Map<Id, String>();

    global Database.QueryLocator start(Database.BatchableContext bc) {

        Id shippingRT =
            Schema.SObjectType.AddressBook__c
                .getRecordTypeInfosByDeveloperName()
                .get('Shipping')
                .getRecordTypeId();

        return Database.getQueryLocator([
            SELECT Id,
                   CITY__c,
                   PINCODE__c,
                   AI_short_code__c,
                   Customer__c,
                   RecordTypeId,
                   Customer__r.Name,
                   Customer__r.RecordTypeId,
                   Customer__r.PAN_Number_of_Entity__c
            FROM AddressBook__c
            WHERE RecordTypeId           = :shippingRT
            AND   Is_Shipping_Address__c = true
            AND   Is_Active__c           = true
            AND   CITY__c                != null
            AND   PINCODE__c             != null
            AND   Customer__c            != null
        ]);
    }

    global void execute(Database.BatchableContext bc, List<AddressBook__c> scope){

        List<AddressBook__c> upd = new List<AddressBook__c>();

        Integer passedV1          = 0;
        Integer passedV2          = 0;
        Integer passedV3          = 0;
        Integer skippedBlankPAN   = 0;
        Integer skippedInvalidPAN = 0;
        Integer skippedRTMismatch = 0;

        // Group by customer for AI sequence
        Map<Id, List<AddressBook__c>> customerAddressMap = new Map<Id, List<AddressBook__c>>();

        for(AddressBook__c a : scope){

            // =============================================
            // VALIDATION 1: Shipping + Active (via start)
            // =============================================
            passedV1++;
            System.debug('✅ V1 PASSED — Shipping + Active | AddressBook: ' + a.Id
                       + ' | Customer: ' + a.Customer__c);

            // =============================================
            // RT MISMATCH CHECK
            // =============================================
            if(a.RecordTypeId != a.Customer__r.RecordTypeId){
                skippedRTMismatch++;
                failedRecords.put(a.Id, 'RT MISMATCHED — AddressBook RT: '
                    + a.RecordTypeId
                    + ' | Customer RT: '
                    + a.Customer__r.RecordTypeId);
                System.debug('❌ RT MISMATCH | AddressBook: ' + a.Id
                           + ' | AddressBook RT: ' + a.RecordTypeId
                           + ' | Customer RT: '    + a.Customer__r.RecordTypeId
                           + ' | Customer: '       + a.Customer__r.Name);
                continue;
            }

            // =============================================
            // VALIDATION 2: PAN ID format check
            // =============================================
            String pan = a.Customer__r.PAN_Number_of_Entity__c;

            if(String.isBlank(pan)){
                skippedBlankPAN++;
                System.debug('❌ V2 FAILED — Blank PAN | AddressBook: ' + a.Id
                           + ' | Customer: ' + a.Customer__c);
                continue;
            }

            Matcher m = PAN_PATTERN.matcher(pan.trim().toUpperCase());
            if(!m.matches()){
                skippedInvalidPAN++;
                System.debug('❌ V2 FAILED — Invalid PAN: ' + pan
                           + ' | AddressBook: ' + a.Id
                           + ' | Customer: '    + a.Customer__c);
                continue;
            }

            passedV2++;
            System.debug('✅ V2 PASSED — Valid PAN: ' + pan
                       + ' | AddressBook: ' + a.Id
                       + ' | Customer: '    + a.Customer__c);

            // Group valid records by customer for V3
            if(!customerAddressMap.containsKey(a.Customer__c)){
                customerAddressMap.put(a.Customer__c, new List<AddressBook__c>());
            }
            customerAddressMap.get(a.Customer__c).add(a);
        }

        // =============================================
        // VALIDATION 3: Assign AI-001 sequence per customer
        // =============================================

        // Get existing max sequence per customer
        Map<Id, Integer> customerMaxSeq = new Map<Id, Integer>();

        for(AddressBook__c existing : [
            SELECT Id, Customer__c, AI_short_code__c
            FROM AddressBook__c
            WHERE Customer__c          IN :customerAddressMap.keySet()
            AND   AI_short_code__c     LIKE 'AI-%'
            AND   Is_Active__c         = true
        ]){
            String code = existing.AI_short_code__c;
            try{
                Integer seq = Integer.valueOf(code.substring(3));
                Id cust = existing.Customer__c;
                if(!customerMaxSeq.containsKey(cust)
                    || customerMaxSeq.get(cust) < seq){
                    customerMaxSeq.put(cust, seq);
                }
            } catch(Exception e){
                // ignore non-numeric codes
            }
        }

        for(Id custId : customerAddressMap.keySet()){

            Integer seq = customerMaxSeq.containsKey(custId)
                        ? customerMaxSeq.get(custId)
                        : 0;

            for(AddressBook__c a : customerAddressMap.get(custId)){

                // Skip if already has valid AI- code
                if(String.isNotBlank(a.AI_short_code__c)
                   && a.AI_short_code__c.startsWith('AI-')){
                    System.debug('⏭️  V3 SKIPPED — Code Already Exists: '
                               + a.AI_short_code__c
                               + ' | AddressBook: ' + a.Id);
                    continue;
                }

                seq++;
                String newCode = 'AI-' + String.valueOf(seq).leftPad(3, '0');

                a.AI_short_code__c = newCode;
                upd.add(a);
                passedV3++;

                System.debug('✅ V3 PASSED — Code Assigned: ' + newCode
                           + ' | AddressBook: ' + a.Id
                           + ' | Customer: '    + custId);
            }
        }

        // BATCH CHUNK SUMMARY
        System.debug('======== BATCH CHUNK SUMMARY ========');
        System.debug('Total in Scope                   : ' + scope.size());
        System.debug('✅ Passed V1 (Shipping + Active) : ' + passedV1);
        System.debug('✅ Passed V2 (Valid PAN)         : ' + passedV2);
        System.debug('✅ Passed V3 (Code Assigned)     : ' + passedV3);
        System.debug('❌ RT Mismatched                 : ' + skippedRTMismatch);
        System.debug('❌ Skipped — Blank PAN           : ' + skippedBlankPAN);
        System.debug('❌ Skipped — Invalid PAN         : ' + skippedInvalidPAN);
        System.debug('=====================================');

        if(!upd.isEmpty()){
            Database.SaveResult[] sr = Database.update(upd, false);

            for(Integer i = 0; i < sr.size(); i++){
                if(!sr[i].isSuccess()){
                    for(Database.Error e : sr[i].getErrors()){
                        failedRecords.put(upd[i].Id, e.getMessage());
                        System.debug('❌ FAILED UPDATE | AddressBook: ' + upd[i].Id);
                        System.debug('Reason: ' + e.getMessage());
                    }
                } else {
                    System.debug('💾 SAVED — AddressBook: ' + upd[i].Id
                               + ' | Code: ' + upd[i].AI_short_code__c);
                }
            }
        }
    }

    global void finish(Database.BatchableContext bc){

        // =============================================
        // FULL RECORD LEVEL COLUMN REPORT
        // =============================================
        List<AddressBook__c> allRecords = [
            SELECT Id,
                   Name,
                   Customer__c,
                   Customer__r.Name,
                   RecordTypeId,
                   Customer__r.RecordTypeId,
                   AI_short_code__c,
                   Customer__r.PAN_Number_of_Entity__c
            FROM AddressBook__c
            WHERE Is_Shipping_Address__c = true
            AND   Is_Active__c           = true
            AND   Customer__c            != null
        ];

        Integer totalProcessed    = 0;
        Integer totalRTMismatch   = 0;
        Integer totalPANBlank     = 0;
        Integer totalPANInvalid   = 0;
        Integer totalPANValid     = 0;
        Integer totalCodeStamped  = 0;
        Integer totalAlreadyHad   = 0;

        System.debug('');
        System.debug('==================================================================================================');
        System.debug('| ADDRESSBOOK ID       | CUSTOMER NAME           | PAN            | AI CODE   | STATUS          |');
        System.debug('==================================================================================================');

        for(AddressBook__c a : allRecords){
            totalProcessed++;

            String pan    = a.Customer__r.PAN_Number_of_Entity__c;
            String status = '';

            // RT Mismatch check
            if(a.RecordTypeId != a.Customer__r.RecordTypeId){
                totalRTMismatch++;
                status = 'RT MISMATCHED';
            }
            // PAN blank check
            else if(String.isBlank(pan)){
                totalPANBlank++;
                status = 'BLANK PAN';
            }
            // PAN format check
            else {
                Matcher m = PAN_PATTERN.matcher(pan.trim().toUpperCase());
                if(!m.matches()){
                    totalPANInvalid++;
                    status = 'INVALID PAN';
                } else {
                    totalPANValid++;
                    if(String.isNotBlank(a.AI_short_code__c)
                       && a.AI_short_code__c.startsWith('AI-')){
                        totalAlreadyHad++;
                        status = 'AI CODE EXISTS';
                    } else {
                        totalCodeStamped++;
                        status = 'CODE STAMPED';
                    }
                }
            }

            System.debug('| ' + String.valueOf(a.Id).leftPad(20)
                       + ' | ' + String.valueOf(a.Customer__r.Name).leftPad(23)
                       + ' | ' + String.valueOf(pan).leftPad(14)
                       + ' | ' + String.valueOf(a.AI_short_code__c).leftPad(9)
                       + ' | ' + status
                       + ' |');
        }

        System.debug('==================================================================================================');

        // =============================================
        // RT MISMATCH DETAIL TABLE
        // =============================================
        System.debug('');
        System.debug('====================== RT MISMATCH RECORDS ======================');
        System.debug('| ADDRESSBOOK ID       | CUSTOMER NAME           | REASON       |');
        System.debug('=================================================================');
        for(Id fid : failedRecords.keySet()){
            if(failedRecords.get(fid).contains('RT MISMATCHED')){
                System.debug('| ' + String.valueOf(fid).leftPad(20)
                           + ' | RT MISMATCHED'
                           + ' |');
            }
        }
        System.debug('=================================================================');

        // =============================================
        // FAILED DML TABLE
        // =============================================
        System.debug('');
        System.debug('====================== FAILED DML RECORDS =======================');
        System.debug('| ADDRESSBOOK ID       | REASON                                 |');
        System.debug('=================================================================');
        for(Id fid : failedRecords.keySet()){
            if(!failedRecords.get(fid).contains('RT MISMATCHED')){
                System.debug('| ' + String.valueOf(fid).leftPad(20)
                           + ' | ' + failedRecords.get(fid)
                           + ' |');
            }
        }
        System.debug('=================================================================');

        // =============================================
        // GRAND SUMMARY
        // =============================================
        System.debug('');
        System.debug('==================== GRAND SUMMARY ====================');
        System.debug('Total Records Evaluated    : ' + totalProcessed);
        System.debug('✅ Valid PAN               : ' + totalPANValid);
        System.debug('✅ AI Code Stamped         : ' + totalCodeStamped);
        System.debug('✅ AI Code Already Existed : ' + totalAlreadyHad);
        System.debug('❌ RT Mismatched           : ' + totalRTMismatch);
        System.debug('❌ Blank PAN               : ' + totalPANBlank);
        System.debug('❌ Invalid PAN             : ' + totalPANInvalid);
        System.debug('❌ Failed DML Updates      : ' + failedRecords.size());
        System.debug('=======================================================');

        // =============================================
        // DUPLICATE SUMMARY
        // =============================================
        List<AggregateResult> globalAgg = [
            SELECT AI_short_code__c c, COUNT(Id) ct
            FROM AddressBook__c
            WHERE AI_short_code__c != null
            AND   Is_Active__c      = true
            GROUP BY AI_short_code__c
            HAVING COUNT(Id) > 1
        ];

        Integer dupTotal = 0;
        for(AggregateResult a : globalAgg){
            dupTotal += ((Integer)a.get('ct') - 1);
        }

        System.debug('');
        System.debug('============= DUPLICATE SUMMARY =============');
        System.debug('Total Duplicate Shipping Addresses : ' + dupTotal);
        System.debug('=============================================');

        // =============================================
        // CUSTOMER WISE DUPLICATE SUMMARY
        // =============================================
        List<AggregateResult> custAgg = [
            SELECT Customer__c cust,
                   AI_short_code__c code,
                   COUNT(Id) ct
            FROM AddressBook__c
            WHERE AI_short_code__c != null
            AND   Is_Active__c      = true
            GROUP BY Customer__c, AI_short_code__c
            HAVING COUNT(Id) > 1
        ];

        Map<Id,Integer> custDup = new Map<Id,Integer>();
        for(AggregateResult a : custAgg){
            Id c       = (Id)a.get('cust');
            Integer ct = (Integer)a.get('ct') - 1;
            if(!custDup.containsKey(c)) custDup.put(c, 0);
            custDup.put(c, custDup.get(c) + ct);
        }

        System.debug('');
        System.debug('============= CUSTOMER DUPLICATE SUMMARY =============');
        System.debug('| CUSTOMER ID          | DUPLICATE COUNT              |');
        System.debug('======================================================');
        for(Id c : custDup.keySet()){
            System.debug('| ' + String.valueOf(c).leftPad(20)
                       + ' | ' + custDup.get(c)
                       + ' |');
        }
        System.debug('======================================================');
    }
}