
// Lending.sol
// Copyright (C) 2017  Juanjo Alvarez Martinez

//This program is free software: you can redistribute it and/or modify
//it under the terms of the GNU General Public License as published by
//the Free Software Foundation, either version 3 of the License, or
//(at your option) any later version.

//This program is distributed in the hope that it will be useful,
//but WITHOUT ANY WARRANTY; without even the implied warranty of
//MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//GNU General Public License for more details.

//You should have received a copy of the GNU General Public License
//along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity^0.4.8;

// TODO refinancing (increase in leftPayments, change in amount). Must be signed
// by 4/5 of all lenders and the solicitor.

// TODO check if Lender can be a separate Contract with methods

// TODO denying mechanism

// TODO check if there is something like a "periodic" execution in Solidity

// TODO support total and partial cancelations with reduced interest in proportion
// to (amountReturned - amountRequested), the amount left, and the time left. 

// TODO iterate over lenders to know what ones to retire when the lending starts:
// https://ethereum.stackexchange.com/questions/12145/how-to-loop-through-mapping-in-solidity

// TODO: add a log of repayments (or a way to retrieve it from the blockchain)

contract Lend {
    // ~~~~~~~~~~~~~ constants  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    uint constant secondsPerDay = 3600; // TODO: leap seconds? check the time functions...
    uint constant minSecondsBetweenPayments = 1 * secondsPerDay;
    // ~~~~~~~~~~~~~ data types ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    // LendReporters investigate LendRequests (Solicitor finances, collaterals,
    // etc). It doesn't neccesarily be a lender; it could be another user.
    struct LendReporter {
        address reporter;
        LendRequestReport[] reports;
    }

    enum ReportStatus = {InProgress, Finished}
    // A report done by a LendReporter. It could have a price attached.
    struct LendRequestReport {
        LendReporter reporter;
        // Free text of the report, written by the reporter
        string reportText;
        // 0 to 100 (100 is better)
        uint8 lendQualification;
        ReportStatus status;
    }

    // This is a request for a lend. It can be browsed by any potential Lender.
    struct LendRequest {
        // The requested amount that the solicitor would inmediately get from the lenders
        // if the Lend is approved
        uint amountRequested;
        // The total returned amount
        uint amountReturned;
        // The number of payments that the solicitor want to pay
        uint32 numPayments;
        // Time between payments
        uint64 secondsBetweenPayments;

        string purpose;
        mapping (address => LendRequestReport) lendReports;

        // TODO: property: Amount locked but still not aproved by the lenders
        //uint totalAmountLocked;

        // Amount aproved by the lenders. When this is greated than amountRequested
        // the LendRequest will close and the InProgressLend will start. Then any 
        // potential lenders with an Lender.approved = false will be returned their
        // Lender.amount and removed from this.Lenders.
        uint totalAmountApproved;
        uint totalAmountLocked;
    }

    struct InProgressLend {
        uint pendingAmount;
        //uint leftPayments; => TODO calculated from pendingAmount/amountPerPayment
        uint amountPerPayment;
        uint64 lastPaymentTstamp;
        uint64 nextPaymentTstamp;
        uint64 secondsBetweenPayments;

        // If the solicitor delays a payment or sent less than the expected
        // amount, this is the interest that will be used to increase the
        // amount per hour. This interest is calculated from the pending
        // payment amount, not the total, but it will be added to the total and
        // thus leftPayments could be increased). 

        // If the solicitor sends part or a total of the
        // pending amount (with or without the increased interest) it will not
        // change the last/next payment dates.
        uint paymentDefaultInterestPerHour;
    }

    // When a lender approves the lend, the amountLended goes from this.totalLocked
    // to this.totalApproved. When totalApproved >= LendRequest.amount, the Lend is approved
    // and any Lenders that have not signed are removed and their amount returned.
    struct Lender {
        address lender;
        uint _amount;
        bool approved = false;
    }

    // ~~~~~~~~~~~~~ data members ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ 

    address public solicitor
    mapping (address => Lender) lenders;
    // XXX sync
    address[] lendersAddrs; // because you can't really iterate a map in Solidity...

    // This is initially filled. Once enough lenders have signed and the status has 
    // changed to InProgress, the lendRequest will be converted into the approvedLend.
    LendRequest public lendRequest;
    InProgressLend public inProgressLend;

    enum LendStatus = {Requested, Denied, InProgress, Paid}
    LendStatus status = LendStatus.Requested;

    // ~~~~~~~~~~~~~ function members ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    function Lend(uint amountRequested, uint amountReturned, uint32 numPayments, 
                  uint64 secondsBetweenPayments, string purpose) {
        require(msg.amount == 0);
        require(status == LendStatus.Requested);
        require(amountRequested > 0);
        require(amountReturned > 0);
        require(amountReturned >= amountRequested);
        require(numPayments > 0);
        require(secondsBetweenPayments >= minSecondsBetweenPayments);
        require(purpose.length > 200); 

        solicitor = msg.sender;
        lendRequest.amountRequested = amountRequested;
        lendRequest.amountReturned = amountReturned;
        lendRequest.numPayments = numPayments;
        lendRequest.secondsBetweenPayments = secondsBetweenPayments;
        lendRequest.purpose = purpose;
    }

    function lenderJoin() {
        require(status == LendStatus.Requested);
        require(lenders[msg.sender] == address(0x0));

        Lender l = Lender({
            lender   : msg.sender,
            _amount  : msg.value,
            approved : false
        });
        lendRequest.totalAmountLocked += msg.value;
        lenders[msg.sender] = l;
        lendersAddrs.push(l);
    }

    function lenderAddAmount() {
        Lender l = lenders[msg.sender];

        // Must be already a lender:
        require(l.address != address(0x0));

        // Can't add funds to an InProgress, Denied or Finished lend:
        require(status == LendStatus.Requested);
        // Can't add once the lender has approved the request
        require(!(lenders[msg.sender].approved));

        l.amount += msg.value;
        lendRequest.totalAmountLocked += msg.value;
    }

    function lenderRetireAmount(uint _amount) {
        Lender l = lenders[msg.sender];

        // Must be already a lender:
        require(l.lender != address(0x0));
        // Can't add funds to an InProgress, Denied or Finished lend:
        require(status == LendStatus.Requested);
        // Can't retire funds if the lender has approved the request
        require(!(l.approved));
        // Can't retire all the funds (that's what lenderRetire is for, not 
        // calling it automatically to avoid accidental retirements)
        require(msg.value > l._amount);

        lendRequest.totalAmountLocked -= _amount;
        l.amount -= _amount;
        msg.sender.send(_amount);
    }

    function lenderRetire() {
        Lender l = lenders[msg.sender];

        require(l.address != address(0x0));
        // Can't retire after the lending has been aproved (lenders that
        // didn't approve the lend are automatically retired when the lending starts)
        require(status != LendStatus.Requested);
        // Can't retire once the lender has approved the request
        require(!(l.approved));

        lendRequest.totalAmountLocked -= l._amount;
        msg.sender.send(l._amount);
        // TEST: test that this really works
        delete lenders[msg.sender];
        // XXX remove from lendersAddrs too!
    }

    function activateLend() {
        // Remove lenders that didn't approve
        for (uint i = 0; i < lendersAddrs.length; i++) {
            if (!lenders[lendersAddrs[i]].approved) {
                lenderRetire(msg.sender);
            }
        }

        status = LendStatus.InProgress;
        solicitor.send(this.amount);
    }

    // TODO:
    // lenderApprove() (can trigger status change, adds signature)
    // activateLend() (remove lenders without approval)
    // lenderDenyLend() (retire and vote for deny)
    // receivePayment() (check for defaulted payment dates, send money to lenders in 
    // proportion to the amount provided).
    // lendPaid()  (change status, remove lenders, finish/delete contract).
    // refinance() (change amountPerPayment, must be signed by everybody)
}
