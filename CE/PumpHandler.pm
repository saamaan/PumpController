package CE::PumpHandler;

use strict;
use warnings;

use CE::UI;
use CE::PumpInterface;

use AnyEvent::CouchDB;
# use Try::Tiny;
use Try::Tiny::Retry;
use DateTime;
use Switch;

use Data::Dumper;

sub new {
	my $class = shift;

	my $self = {};
	$self->{db_uri} = shift;
#	$self->{couch} = couchdb('http://cowichanenergy/couchdb/testdb');
	$self->{couch} = couchdb( $self->{db_uri} );
	$self->{loc} = shift || 'RA';
	$self->{tax_area} = shift || 'BC';
	$self->{ttID} = "tank_tracking:" . $self->{loc};

	$self->{terms} = shift;
	$self->{UI} = CE::UI->new( $self->{terms} );
	$self->{PI} = CE::PumpInterface->new();

	return bless($self, $class);
}

sub run {
	my $self = shift;

	#my $PI = CE::PumpInterface->new();

	my $UI = $self->{UI};
	my $PI = $self->{PI};
	my $couch = $self->{couch};

	my @resp;
	my $checkedOut = 0;
	my ($id, $p, $num, $vol, $bail); $bail = 0;

	while ( $self->_idle() ) {
		my $currentDate = localtime();
		warn $currentDate, "\n";

		$num = $UI->promptFeedback("User ID + Enter", \@resp, 7, 'fb');
		if ($num == $UI->timeoutError) {
			$UI->message("Timeout");
			sleep(6);
			$bail = 1;
		}
		goto BAIL if ( $bail == 1);

		$UI->message("Please wait..");

		$id = join('', @resp[0..($num - 1)]);
		my $docID = "member:$id";

		my ($doc, $prices, $tank_tracking);
		try {
			$tank_tracking = $couch->open_doc($self->{ttID})->recv();
			warn "Tank tracking info acquired.";
		}
		catch {
			warn "catch error message: $_.\nNo tank tracking, will continue\n";
		};
		goto BAIL if ( $bail == 1);

		try {
			$doc = $couch->open_doc($docID)->recv();
			if ( (exists $doc->{price_per_litre_diesel}) and 
				(exists $doc->{price_per_litre_biodiesel}) ) {
				$prices = { ppl_diesel => $doc->{price_per_litre_diesel},
						ppl_biodiesel => $doc->{price_per_litre_biodiesel}};

				warn "prices acquired.";
			}
			else {
				warn "Member missing price info.";
				$UI->message("No prices found");
				sleep(6);
				$bail = 1;
			}
		}
		catch {		
			#check the error message here. This could also happen due to DB connection failure..
			warn "catch error message: $_\n";

			if ( /404 - / ) {
				$UI->message("ID invalid");
			}
			else {
				$UI->message("No DB connection");
			}
			sleep(6);
			$bail = 1;
		};
		goto BAIL if ( $bail == 1);

		if ( $doc->{member_id} == $id ) {
			if ( (defined $doc->{frozen}) and ($doc->{frozen} == 1) ) {
				$UI->message("Account frozen");
				sleep(3);
				$bail = 1;
			}
			if ( (not defined $doc->{payment_hash}) or ($doc->{payment_hash} eq "") ) {
				$UI->message("Payment profile", "missing");
				sleep(3);
				$bail = 1;
			}
			goto BAIL if ( $bail == 1);


			$num = $UI->promptFeedback("PIN + Enter", \@resp, 4, 'scramble');
			if ($num == $UI->timeoutError) {
				$UI->message("Timeout");
				sleep(6);
				$bail = 1;
			}
			goto BAIL if ( $bail == 1);

			$p = join('', @resp[0..($num - 1)]);
			unless ( $p == $doc->{PIN} ) {
				$UI->message("Invalid PIN");
				sleep(6);
				$bail = 1;
			}
			goto BAIL if ( $bail == 1);

			
			$UI->message("PIN OK!");
			sleep(3);

			$UI->message("Remove nozzle", "and select type");
			my $ret;

			$ret = $PI->waitForType();
			if ($ret eq $PI->timeoutError) {
				$UI->message("Timeout");
				sleep(6);
				$bail = 1;
			}
			goto BAIL if ( $bail == 1);

			my $type = $ret;

			$ret = $PI->waitForNozzleRemoval();
			warn "waitForNozzle returned $ret.";
			if ($ret eq $PI->timeoutError) {
				$UI->message("Timeout");
				sleep(6);
				$bail = 1;
			}
			goto BAIL if ( $bail == 1);

			my $nozzle = $ret;

			$PI->enablePumps();

			$UI->message("$type selected", "Begin fueling");
			# sleep(2);


			my $pumpData = $PI->intercept($nozzle);
			$PI->disablePumps();
			#gotta take out the taxes and stuff

			if ( not defined $pumpData->{vol} ) {
				warn "Pump data was invalid.";
				$bail = 1;
			}
			goto BAIL if ( $bail == 1);

			if ($pumpData->{vol} == 0) {
				warn "Session ended without any fuel being dispensed.";
				$bail = 1;
			}
			goto BAIL if ( $bail == 1);


			my $pricePerLiter = sprintf("%.4f", $pumpData->{cost} / $pumpData->{vol});
			my $data_hash = {
					member_id => $id,
					vol => $pumpData->{vol},
					##priceFromDispsr => $pricePerLiter,
					total_price => $pumpData->{cost},
					product_type => $type
					};
			_mixToLitres($data_hash, $prices);

			$ret = $self->_pushTXN($tank_tracking, $data_hash);
			#TODO: this probably means something serious is wrong, not "next" probably!
			warn "_pushTXN returned $ret.\n";
			if ($ret) {
				warn "$data_hash->{member_id}, $data_hash->{vol}," .
						" $data_hash->{total_price}, $data_hash->{product_type}" . 
						".\n";
				goto BAIL;
			}

			#$num = $UI->promptFeedback("Volume (e.g. 13)", \@resp, 3, 'fb');
			#if ($num == $UI->timeoutError) {
			#	$UI->message("Timeout");
			#	sleep(3);
			#	next;
			#}
			#$vol = join('', @resp[0..($num - 1)]);


			$UI->message("$pumpData->{vol}".'L', '$'."$data_hash->{total_price}");
			sleep(24);
			$pumpData = undef;
		
		}
		else {
			#this shouldn't happen unless the DB records are messed up.
			#probably log some thing or send a message to admin or something..
		}
		

		#$num = $UI->promptFeedback("PIN + Enter", \@resp, 4, 'scramble');
		#$p = join('', @resp[0..($num - 1)]);
		#$checkedOut = authenticate($p);

		BAIL: $bail = 0;
	}

	$PI->destroy();
	$UI->destroyUI();

	warn "UI destroyed normally\n";

	#for (my $i = 0; $i < 10; $i++) {
	#	$PI->enablePump();
	#	$PI->delayMS(500);
	#	$PI->disablePump();
	#	$PI->delayMS(500);
	#}
	#
	#my $fm = $PI->pollFMPin();
	#my $nr = $PI->pollNozzleRemoved();

	#print "flow meter: $fm, nozzle removed: $nr\n";
}

#user authentication
#this should talk to the DB...
sub authenticate {
	my $PIN = shift;

	return $PIN == 1234 ? 1 : 0;
}

sub destroy {
	my $self = shift;

	$self->{PI}->destroy();
	$self->{UI}->destroyUI();
}

#put try catch blocks here
sub _pushTXN {
	my $self = shift;

	my $tt_info = shift;
	my $args = shift;

	my $dt = DateTime->now();
	my $txn_id = $args->{member_id} . "." . $dt->epoch;

	my $txn_hash = {
		Type => 'txn',
		_id => "txn:" . $txn_id,
		txn_id => $txn_id,
		member_id => $args->{member_id},
		epoch_time => $dt->epoch,
		litres => $args->{vol},
		litres_diesel => $args->{vol_diesel},
		litres_biodiesel => $args->{vol_biodiesel},
		price_per_litre_diesel => $args->{ppl_diesel},
		price_per_litre_biodiesel => $args->{ppl_biodiesel},
		mix => $args->{product_type},
		date => "$dt",
		#price_per_litre => $args->{priceFromDispsr},
		price => $args->{total_price},
		paid => 0,
		tax_area => $self->{tax_area},
		pump => $self->{loc}
	};

	my $str = Dumper($txn_hash);
	warn "txn hash: $str";

	retry {
		$self->{couch}->save_doc($txn_hash)->recv();
	}
	retry_if { not /^404 - / }
	on_retry {
		warn "Error: $_, Retrying...\n";
		$self->{UI}->message("No DB connection", "Retrying...");
	}
	delay_exp { 4, 1e6 }
	catch {
		#TODO this should obviously do something else!
		#check the error message here. This could also happen due to DB connection failure..
		warn "catch error message: $_\n";

		if ( /404 - / ) {
			$self->{UI}->message("ID invalid");
		}
		else {
			$self->{UI}->message("No DB connection");
		}
		return -1;
	};

	if (not defined $tt_info) {
		return 0;
	}
	$tt_info->{diesel_vol} -= $args->{vol_diesel};
	$tt_info->{biodiesel_vol} -= $args->{vol_biodiesel};
	retry {
		$self->{couch}->save_doc($tt_info)->recv();
	}
	retry_if { not /^404 - / }
	on_retry {
		warn "Error: $_, Retrying...\n";
		$self->{UI}->message("No DB connection", "Retrying...");
	}
	delay_exp { 4, 1e6 }
	catch {
		warn "Error updating tank tracking info $_\n." .
				"Diesel: $tt_info->{diesel_vol}, and Biodiesel: $tt_info->{biodiesel_vol}.\n";
	};

	return 0;
}

#TODO verify the connection to the server periodically?
sub _idle {
	my $self = shift;

#	$self->{UI}->emptyBuffer();

	$self->{UI}->message("Press Enter");
	return $self->{UI}->waitForStart();
}

#there maybe some round off errors cuz these are calculated..
#diesel vol = total vol * mix ratio ('0.02f')
#biodiesel_vol = total vol - diesel vol
sub _mixToLitres {
        my $txn_hash = shift;
	my $prices = shift;

    my $vol = $txn_hash->{vol};
    switch ( $txn_hash->{product_type} ) {
            case 'Diesel' {
                    $txn_hash->{vol_diesel} = $vol;
            }
            case 'B20' {
                    $txn_hash->{vol_diesel} = sprintf('%0.03f', ($vol * 0.8));
            }
            case 'B50' {
                    $txn_hash->{vol_diesel} = sprintf('%0.03f', ($vol * 0.5));
            }
            case 'B100' {
                    $txn_hash->{vol_diesel} = '0.0';
            }
            else {
                    die "Undefined product type: $txn_hash->{product_type}.";
            }
    }

    $txn_hash->{vol_biodiesel} = $vol - $txn_hash->{vol_diesel};
	$txn_hash->{ppl_diesel} = $prices->{ppl_diesel};
	$txn_hash->{ppl_biodiesel} = $prices->{ppl_biodiesel};
	$txn_hash->{total_price} = 
		( $txn_hash->{vol_biodiesel} * $txn_hash->{ppl_biodiesel}) +
		($txn_hash->{vol_diesel} * $txn_hash->{ppl_diesel});

	# print "Mix: $txn_hash->{product_type}.\n";
	# print "ppl_d: $txn_hash->{ppl_diesel}, ppl_bd: $txn_hash->{ppl_biodiesel}.\n";
	# print "vol_d: $txn_hash->{vol_diesel}, vol_bd: $txn_hash->{vol_biodiesel}.\n";
	# print "total: $txn_hash->{total_price}.\n";

	$txn_hash->{total_price} = sprintf("%.2f", $txn_hash->{total_price} );

}

1;
